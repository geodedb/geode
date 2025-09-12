const std = @import("std");
const testing = std.testing;

test "NEXT.md contains required sections and profile_version=2 reference" {
    var file = try std.fs.cwd().openFile("docs/NEXT.md", .{});
    defer file.close();
    const data = try file.readToEndAlloc(testing.allocator, 1 << 16);
    defer testing.allocator.free(data);
    const must = [_][]const u8{ "## Now (P0)", "## Next (P1)", "## Later (P2+)", "profile_version=2" };
    for (must) |m| try testing.expect(std.mem.indexOf(u8, data, m) != null);
}
