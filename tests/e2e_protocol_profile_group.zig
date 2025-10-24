const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(args, allocator);
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

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// PROFILE grouped query should include AggregateBuild and AggregateEmit ops.
// Uses grouping form: RETURN 1 AS a GROUP BY a (semantic no-op grouping) to trigger aggregation path.

pub fn main() !void {}

test "protocol: PROFILE grouped query includes aggregate ops" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS a GROUP BY a" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    try std.testing.expect(contains(res.out, "AggregateBuild"));
    try std.testing.expect(contains(res.out, "AggregateEmit"));
    // Project should still appear
    try std.testing.expect(contains(res.out, "Project"));
    // profile_version 1 expectation
    try std.testing.expect(contains(res.out, "\"profile_version\":1"));
    // bytes_out metric should be present
    try std.testing.expect(contains(res.out, "bytes_out"));
    try std.testing.expect(contains(res.out, "input_rows"));
    try std.testing.expect(contains(res.out, "bytes_alloc"));
    // Basic op ordering subset: AggregateBuild -> AggregateEmit -> Project
    const pos_build = std.mem.indexOf(u8, res.out, "\"op\":\"AggregateBuild\"") orelse return error.NoAggregateBuild;
    const pos_emit = std.mem.indexOf(u8, res.out, "\"op\":\"AggregateEmit\"") orelse return error.NoAggregateEmit;
    const pos_project = std.mem.indexOf(u8, res.out, "\"op\":\"Project\"") orelse return error.NoProject;
    try std.testing.expect(pos_build < pos_emit and pos_emit < pos_project);
}
