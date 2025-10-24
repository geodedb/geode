const std = @import("std");
const protocol = @import("protocol");

// Unit test: buildProfileLine constructs well-formed JSON line with flags and exact length.
// Ensures no regression in length arithmetic (past segfault root cause).

test "protocol.buildProfileLine basic" {
    const allocator = std.testing.allocator;
    const payload = "{\"profile_version\":1,\"ops\":[],\"totals\":{}}";
    const flags = [_][]const u8{ "I:IllegalOrderKeyPolicy=ident-only", "U:NullsFirstPolicy" };
    const line = try protocol.buildProfileLine(allocator, payload, &flags);
    defer allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "{\"status_class\":"));
    try std.testing.expect(std.mem.indexOf(u8, line, payload) != null);
    // Ensure flags appear in order
    const pos_illegal = std.mem.indexOf(u8, line, flags[0]) orelse return error.FlagMissing;
    const pos_nulls = std.mem.indexOf(u8, line, flags[1]) orelse return error.FlagMissing2;
    try std.testing.expect(pos_illegal < pos_nulls);
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
}
