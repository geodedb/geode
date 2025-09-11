const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return .{ .out = out };
}

test "protocol: PROFILE includes NodeScan synthetic stage" {
    const exe = "zig-out/bin/geoded";
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT LIMIT 2", "--json-param", "a", "[1,2,2,3]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const line = it.next() orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, line, "\"NodeScan\"") != null);
    // Ensure NodeScan op_index 0 and Project >0
    try testing.expect(std.mem.indexOf(u8, line, "\"NodeScan\",\"op_index\":0") != null or std.mem.indexOf(u8, line, "\"op_index\":0,\"input_rows\":") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"Project\",\"op_index\":0") == null);
}
