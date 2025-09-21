const std = @import("std");
const geode = @import("geode");
const ast = geode.ast;
const exec = @import("server/graph/exec.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchLabelProperty; OWNER=engine; UPDATED=2025-09-21

pub fn TestCANARY_REQ_GQL_017_MatchLabelProperty() !void {
    var g = exec.GraphStorage.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(std.testing.allocator, 1, &.{"Person"});
    try g.addNode(std.testing.allocator, 2, &.{"Person"});
    try g.addNode(std.testing.allocator, 3, &.{"Animal"});

    try g.setNodeProperty(1, "name", .{ .String = "Alice" });
    try g.setNodeProperty(2, "name", .{ .String = "Bob" });
    try g.setNodeProperty(3, "name", .{ .String = "Cat" });

    // Build node pattern (n:Person { name: "Alice" })
    const name_expr = try std.testing.allocator.create(ast.Expr);
    name_expr.* = .{ .String = "Alice" };
    const prop = ast.Property{ .key = "name", .value = name_expr };

    const node_pat = ast.NodePattern{ .name = "n", .labels = &.{"Person"}, .props = &.{prop} };
    const right_pat = ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const rel = ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop = ast.Hop{ .left = node_pat, .rel = rel, .right = right_pat };
    const chain = ast.Chain{ .name = null, .hops = &.{hop} };
    const pattern = ast.GraphPattern{ .chains = &.{chain} };

    const bindings = try exec.executeMatch(std.testing.allocator, &g, pattern, null);
    defer std.testing.allocator.free(bindings);

    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    const b = bindings[0];
    const val = b.vars.get("n") orelse return error.ExpectedVar;
    switch (val) {
        .Node => |nid| try std.testing.expectEqual(@as(u64, 1), nid),
        else => return error.UnexpectedBindingType,
    }

    // Negative label (should yield zero)
    const node_pat_neg = ast.NodePattern{ .name = "x", .labels = &.{"DoesNotExist"}, .props = &.{prop} };
    const hop_neg = ast.Hop{ .left = node_pat_neg, .rel = rel, .right = right_pat };
    const chain_neg = ast.Chain{ .name = null, .hops = &.{hop_neg} };
    const pattern_neg = ast.GraphPattern{ .chains = &.{chain_neg} };
    const bindings_neg = try exec.executeMatch(std.testing.allocator, &g, pattern_neg, null);
    defer std.testing.allocator.free(bindings_neg);
    try std.testing.expectEqual(@as(usize, 0), bindings_neg.len);
}

fn hashBindings(bindings: []const exec.Binding) u64 {
    var h: u64 = 0;
    for (bindings) |b| {
        var iter = b.vars.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .Node => |nid| h = std.hash.wyhash64(&@as([8]u8, @bitCast(nid)), h),
                else => {},
            }
        }
    }
    return h;
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=EquivalenceDeterminism; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchLabelPropertyEquivalenceDeterminism; OWNER=engine; UPDATED=2025-09-21
pub fn TestCANARY_REQ_GQL_017_MatchLabelPropertyEquivalenceDeterminism() !void {
    var g = exec.GraphStorage.init(std.testing.allocator);
    defer g.deinit();

    // Create sample nodes
    try g.addNode(std.testing.allocator, 1, &.{"Person"});
    try g.addNode(std.testing.allocator, 2, &.{"Person"});
    try g.setNodeProperty(1, "name", .{ .String = "Alice" });
    try g.setNodeProperty(2, "name", .{ .String = "Alice" });

    // Inline predicate pattern (n:Person { name: "Alice" })
    const name_expr1 = try std.testing.allocator.create(ast.Expr);
    name_expr1.* = .{ .String = "Alice" };
    const prop1 = ast.Property{ .key = "name", .value = name_expr1 };
    const node_pat_inline = ast.NodePattern{ .name = "n", .labels = &.{"Person"}, .props = &.{prop1} };
    const dummy_node = ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const rel = ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop_inline = ast.Hop{ .left = node_pat_inline, .rel = rel, .right = dummy_node };
    const chain_inline = ast.Chain{ .name = null, .hops = &.{hop_inline} };
    const pattern_inline = ast.GraphPattern{ .chains = &.{chain_inline} };
    const inline_bindings = try exec.executeMatch(std.testing.allocator, &g, pattern_inline, null);
    defer std.testing.allocator.free(inline_bindings);

    // WHERE form: MATCH (m:Person) WHERE m.name = "Alice"
    const name_expr2 = try std.testing.allocator.create(ast.Expr);
    name_expr2.* = .{ .String = "Alice" };
    const ident_m = try std.testing.allocator.create(ast.Expr);
    ident_m.* = .{ .Ident = "m" };
    const prop_access = ast.Expr{ .PropertyAccess = .{ .object = "m", .property = "name" } };
    const lit = ast.Expr{ .String = "Alice" };
    const where_expr = ast.Expr{ .Binary = .{ .op = .Eq, .left = blk: {
        const p = try std.testing.allocator.create(ast.Expr);
        p.* = prop_access;
        break :blk p;
    }, .right = blk2: {
        const q = try std.testing.allocator.create(ast.Expr);
        q.* = lit;
        break :blk2 q;
    } } };
    const node_pat_where = ast.NodePattern{ .name = "m", .labels = &.{"Person"}, .props = null };
    const hop_where = ast.Hop{ .left = node_pat_where, .rel = rel, .right = dummy_node };
    const chain_where = ast.Chain{ .name = null, .hops = &.{hop_where} };
    const pattern_where = ast.GraphPattern{ .chains = &.{chain_where} };
    const where_bindings = try exec.executeMatch(std.testing.allocator, &g, pattern_where, where_expr);
    defer std.testing.allocator.free(where_bindings);

    try std.testing.expectEqual(inline_bindings.len, where_bindings.len);

    // Determinism hash (Wyhash over serialized node ids)

    const hash_inline = hashBindings(inline_bindings);
    const hash_where = hashBindings(where_bindings);
    try std.testing.expectEqual(hash_inline, hash_where);

    // Repeat execution multiple times to ensure stable hash
    var repeat: usize = 0;
    while (repeat < 20) : (repeat += 1) {
        const again_inline = try exec.executeMatch(std.testing.allocator, &g, pattern_inline, null);
        defer std.testing.allocator.free(again_inline);
        try std.testing.expectEqual(hash_inline, hashBindings(again_inline));
    }
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=OptionalMatchNullPreserve; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalMatchNullPreserve; OWNER=engine; UPDATED=2025-09-21
pub fn TestCANARY_REQ_GQL_017_OptionalMatchNullPreserve() !void {
    var g = exec.GraphStorage.init(std.testing.allocator);
    defer g.deinit();

    // Base node without a matching optional pattern
    try g.addNode(std.testing.allocator, 1, &.{"Person"});
    try g.setNodeProperty(1, "name", .{ .String = "Solo" });

    // Pattern: MATCH (n:Person { name: "Solo" }) OPTIONAL MATCH (m:Animal { name: "Ghost" })
    // Build first pattern (n)
    const name_expr1 = try std.testing.allocator.create(ast.Expr);
    name_expr1.* = .{ .String = "Solo" };
    const prop1 = ast.Property{ .key = "name", .value = name_expr1 };
    const node_pat_n = ast.NodePattern{ .name = "n", .labels = &.{"Person"}, .props = &.{prop1} };
    const dummy = ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const rel = ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop_n = ast.Hop{ .left = node_pat_n, .rel = rel, .right = dummy };
    const chain_n = ast.Chain{ .name = null, .hops = &.{hop_n} };
    const pattern_n = ast.GraphPattern{ .chains = &.{chain_n} };
    const base_bindings = try exec.executeMatch(std.testing.allocator, &g, pattern_n, null);
    defer std.testing.allocator.free(base_bindings);
    try std.testing.expectEqual(@as(usize, 1), base_bindings.len);

    // Optional pattern (m:Animal { name: "Ghost" })
    const name_expr2 = try std.testing.allocator.create(ast.Expr);
    name_expr2.* = .{ .String = "Ghost" };
    const prop2 = ast.Property{ .key = "name", .value = name_expr2 };
    const node_pat_opt = ast.NodePattern{ .name = "m", .labels = &.{"Animal"}, .props = &.{prop2} };
    const hop_opt = ast.Hop{ .left = node_pat_opt, .rel = rel, .right = dummy };
    const chain_opt = ast.Chain{ .name = null, .hops = &.{hop_opt} };
    const pattern_opt = ast.GraphPattern{ .chains = &.{chain_opt} };

    // Use executeOptionalMatch to simulate OPTIONAL semantics
    const opt_bindings = try exec.executeOptionalMatch(std.testing.allocator, &g, base_bindings, pattern_opt, null);
    defer std.testing.allocator.free(opt_bindings);
    try std.testing.expectEqual(@as(usize, 1), opt_bindings.len);
    const b = opt_bindings[0];
    // n should be bound, m should be Null
    try std.testing.expect(b.vars.get("n") != null);
    if (b.vars.get("m")) |mv| {
        // OPTIONAL with no match -> Null
        try std.testing.expect(mv == .Null);
    } else return error.ExpectedOptionalVar;
}
