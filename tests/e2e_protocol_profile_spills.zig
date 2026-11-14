const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: PROFILE spills placeholders" {
    const exe = geode_test_bin.geode_exe;
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
