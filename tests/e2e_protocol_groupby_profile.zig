const std = @import("std");
const testing = std.testing;

test "e2e: PROFILE GROUP BY emits HashAgg ops" {
    // Launch server process
    var child = std.process.Child.init(&.{"zig-out/bin/geoded"}, testing.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    defer child.kill() catch {};
    defer child.wait() catch {};
    const stdin_writer = child.stdin.?.writer();
    const stdout_reader = child.stdout.?.reader();
    // Send PROFILE query with GROUP BY
    const q = "{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN count(*) GROUP BY x\"}\n";
    try stdin_writer.writeAll(q);
    // PULL to force PROFILE emission
    try stdin_writer.writeAll("{\"type\":\"PULL\"}\n");
    var buf: [65536]u8 = undefined;
    const n = try stdout_reader.read(&buf);
    const out = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, out, "HashAggBuild") != null);
    try testing.expect(std.mem.indexOf(u8, out, "HashAggEmit") != null);
}
