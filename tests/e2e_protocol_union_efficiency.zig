const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 15);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 15);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return .{ .out = out };
}

test "protocol: PROFILE UNION DISTINCT efficiency metric" {
    const exe = "./zig-out/bin/geodec";
    // Duplicate rows ensure dedup difference; two identical branches.
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer testing.allocator.free(res.out);
    // Look for distinct_fill_pct and ensure within 0-100 and >0 for this case (1 distinct / 2 input -> 50%)
    try testing.expect(std.mem.indexOf(u8, res.out, "\"distinct_fill_pct\"") != null);
    const tag = "\"distinct_fill_pct\":";
    const pos = std.mem.indexOf(u8, res.out, tag) orelse return error.MissingFillPct;
    var i: usize = pos + tag.len;
    while (i < res.out.len and (res.out[i] == ' ')) i += 1;
    const start = i;
    while (i < res.out.len and res.out[i] >= '0' and res.out[i] <= '9') i += 1;
    if (i == start) return error.BadNumber;
    const pct = try std.fmt.parseInt(usize, res.out[start..i], 10);
    try testing.expect(pct <= 100);
    try testing.expect(pct >= 1);
}
