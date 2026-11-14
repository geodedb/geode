const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    return res.out;
}

test "protocol: PROFILE includes Expand stage after NodeScan" {
    const exe = geode_test_bin.geode_exe;
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
