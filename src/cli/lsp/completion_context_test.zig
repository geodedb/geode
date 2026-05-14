const std = @import("std");
const testing = std.testing;
const cc = @import("completion_context.zig");

test "detects label completion after (n:" {
    const ctx = cc.analyze("MATCH (n:", .{ .line = 0, .character = 9 });
    try testing.expectEqual(cc.Kind.label, ctx.kind);
    try testing.expectEqualStrings("", ctx.prefix);
}

test "detects label prefix" {
    const ctx = cc.analyze("MATCH (n:Per", .{ .line = 0, .character = 12 });
    try testing.expectEqual(cc.Kind.label, ctx.kind);
    try testing.expectEqualStrings("Per", ctx.prefix);
}

test "detects edge type after [r:" {
    const ctx = cc.analyze("MATCH (a)-[r:", .{ .line = 0, .character = 13 });
    try testing.expectEqual(cc.Kind.edge_type, ctx.kind);
}

test "detects property after n." {
    const ctx = cc.analyze("RETURN n.", .{ .line = 0, .character = 9 });
    try testing.expectEqual(cc.Kind.property, ctx.kind);
    try testing.expectEqualStrings("n", ctx.var_name orelse "");
}

test "falls back to keyword" {
    const ctx = cc.analyze("MAT", .{ .line = 0, .character = 3 });
    try testing.expectEqual(cc.Kind.keyword, ctx.kind);
    try testing.expectEqualStrings("MAT", ctx.prefix);
}

test "resolveVarLabel finds label from MATCH binding" {
    const text = "MATCH (n:Person)-[r:KNOWS]->(m:Product) RETURN n.";
    try testing.expectEqualStrings("Person", cc.resolveVarLabel(text, "n") orelse "");
    try testing.expectEqualStrings("Product", cc.resolveVarLabel(text, "m") orelse "");
}
