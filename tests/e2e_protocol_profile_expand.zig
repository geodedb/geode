const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: PROFILE includes Expand stage after NodeScan" {
    const exe = "zig-out/bin/geoded";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" });
    defer testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next();
    const profile_line = it.next() orelse return error.MissingProfile;
    const node_idx = std.mem.indexOf(u8, profile_line, "\"NodeScan\"") orelse return error.NoNodeScan;
    const expand_idx = std.mem.indexOf(u8, profile_line, "\"Expand\"") orelse return error.NoExpand;
    const project_idx = std.mem.indexOf(u8, profile_line, "\"Project\"") orelse return error.NoProject;
    try testing.expect(node_idx < expand_idx and expand_idx < project_idx);
}
