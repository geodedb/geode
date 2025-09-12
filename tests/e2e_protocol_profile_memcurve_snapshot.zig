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

// Use shared normalization
fn normalize(line: []const u8, ally: std.mem.Allocator) ![]u8 {
    return util.normalizeNumbers(ally, line);
}

const EXPECTED = "mem_curve\":[{\"op_index\":0,\"net_after_op\":0}"; // intentionally truncated prefix for stability

test "protocol: PROFILE mem_curve snapshot prefix" {
    const exe = "./zig-out/bin/geodec";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1", "--profile-memcurve" });
    defer testing.allocator.free(out);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, pl, "\"mem_curve\":") != null);
    // Check normalized contains expected prefix token order.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const norm = try normalize(pl, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, norm, EXPECTED) != null);
}
