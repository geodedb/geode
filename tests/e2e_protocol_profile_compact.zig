const std = @import("std");
const testing = std.testing;

test "profile compact omits zero-value optional fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Run CLI with PROFILE and compact flag.
    var argv = [_][]const u8{ "zig-out/bin/geode", "query", "PROFILE RETURN 1 AS x", "--profile-compact" };
    var child = std.process.Child.init(&argv, alloc);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    var stdout_buf = std.ArrayList(u8).init(alloc);
    var stderr_buf = std.ArrayList(u8).init(alloc);
    defer stdout_buf.deinit();
    defer stderr_buf.deinit();
    defer stderr_buf.deinit();
    if (child.stdout) |*s| try s.reader().readAllArrayList(&stdout_buf, 10_000);
    if (child.stderr) |*s| try s.reader().readAllArrayList(&stderr_buf, 10_000);
    const term = try child.wait();
    try testing.expectEqual(@as(i32, 0), term.Exited);
    const out = stdout_buf.items;
    // Find PROFILE line (last line).
    var it = std.mem.splitScalar(u8, out, '\n');
    var profile_line: []const u8 = &[_]u8{};
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"ops\"") != null and std.mem.indexOf(u8, line", "\"profile_version\"") != null) {
            profile_line = line;
        }
    }
    try testing.expect(profile_line.len > 0);
    // Zero-value optional fields should be absent for NodeScan: estimate_bytes, estimate_vs_actual, percent_peak, percent_net, freed_bytes, error_bytes, error_abs_pct.
    try testing.expect(std.mem.indexOf(u8, profile_line, "estimate_bytes\":0") == null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "estimate_vs_actual\":0") == null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "percent_peak\":0") == null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "percent_net\":0") == null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "freed_bytes\":0") == null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "error_bytes\":0") == null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "error_abs_pct\":0") == null);
}
