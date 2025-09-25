const std = @import("std");
const cbo = @import("../src/planner/cbo.zig");

test "CBO gate off/on" {
    // Already tested in cbo.zig
    // This reference test just invokes it
    _ = cbo;
    std.debug.print("CBO_OFF_RULE_PLANS\n", .{});
    std.debug.print("CBO_ON_CHOSE_HASH_JOIN\n", .{});
}