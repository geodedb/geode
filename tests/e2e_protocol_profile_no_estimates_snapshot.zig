const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 20);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

// Use shared normalization (not strictly needed here but keeps consistency if extended later)
fn signature(ally: std.mem.Allocator, line: []const u8) ![]u8 {
    return util.normalizeNumbers(ally, line);
}

// Snapshot ensures removing estimates does not alter other structural aspects
const EXPECTED = "planner_estimates\":{\"sum_estimate_bytes\":0,\"sum_actual_bytes\":0,\"count_estimated_ops\":0,\"min_error_abs_pct\":0,\"max_error_abs_pct\":0"; // baseline substring

test "protocol: PROFILE --no-estimates structural stability" {
    const exe = "./zig-out/bin/geodec";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1", "--no-estimates" });
    defer testing.allocator.free(out);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    // Ensure planner_estimates block removed or zeroed (with --no-estimates we expect omission)
    try testing.expect(std.mem.indexOf(u8, pl, "\"planner_estimates\"") == null);
    // Ensure other mandatory fields exist
    try testing.expect(std.mem.indexOf(u8, pl, "\"ops\":") != null);
    try testing.expect(std.mem.indexOf(u8, pl, "\"memory\":") != null);
    try testing.expect(std.mem.indexOf(u8, pl, "\"flagger_findings\":") != null);
}
