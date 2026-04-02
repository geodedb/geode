const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-GQL-MULTIHOP-REGRESSION-001; FEATURE="MultiHopRegression"; ASPECT=SegfaultPrevention; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-02

fn makeContext() !execution.ExecutionContext {
    // Use page_allocator for the catalog singleton — it outlives any individual
    // test, so testing.allocator would report a false-positive leak.
    const catalog = try execution.ensureCatalogInstance(std.heap.page_allocator);
    return execution.ExecutionContext{ .catalog = catalog };
}

fn makeLabels(allocator: std.mem.Allocator, comptime names: []const []const u8) ![][]const u8 {
    var labels = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |name, i| {
        labels[i] = try allocator.dupe(u8, name);
    }
    return labels;
}

fn freeLabels(allocator: std.mem.Allocator, labels: [][]const u8) void {
    for (labels) |label| allocator.free(label);
    allocator.free(labels);
}

// NOTE: makeContext() MUST be called BEFORE creating nodes/edges.
// ensureCatalogInstance() may trigger Catalog.init() → load() →
// store.loadFromFile() → clearNodes(), which wipes the global store.
// By calling makeContext() first, the catalog initialization completes
// before any test data is created.

// GAP-0425: Regression test for multi-hop segfault in text_handler.zig:137
// The crash was caused by unbounded arena growth from leaked edge slices
// allocated by getEdgesFrom/getEdgesTo inside the multi-hop traversal loop.
test "GAP-0425: 3-hop multi-hop query does not crash" {
    const allocator = testing.allocator;
    const context = try makeContext();
    const store = graph_store.getGlobalStore(allocator);

    // Create a Firewall -> Interface -> ACL -> Rule topology (the crashing pattern)
    const fw_labels = try makeLabels(allocator, &.{"MH1_Firewall"});
    defer freeLabels(allocator, fw_labels);
    const iface_labels = try makeLabels(allocator, &.{"MH1_Interface"});
    defer freeLabels(allocator, iface_labels);
    const acl_labels = try makeLabels(allocator, &.{"MH1_ACL"});
    defer freeLabels(allocator, acl_labels);
    const rule_labels = try makeLabels(allocator, &.{"MH1_ACLRule"});
    defer freeLabels(allocator, rule_labels);

    const fw = try store.createNode(fw_labels);
    try store.setNodeProperty(fw, "name", .{ .String = "fw1" });

    const iface = try store.createNode(iface_labels);
    try store.setNodeProperty(iface, "name", .{ .String = "eth0" });

    const acl = try store.createNode(acl_labels);
    try store.setNodeProperty(acl, "name", .{ .String = "inbound" });

    const rule = try store.createNode(rule_labels);
    try store.setNodeProperty(rule, "action", .{ .String = "permit" });

    _ = try store.createEdge(fw, iface, "MH1_HAS_INTERFACE");
    _ = try store.createEdge(acl, iface, "MH1_APPLIED_TO");
    _ = try store.createEdge(acl, rule, "MH1_HAS_RULE");

    // This is the exact query pattern that caused the segfault
    const query =
        \\MATCH (fw:MH1_Firewall)-[r1:MH1_HAS_INTERFACE]->(iface:MH1_Interface)<-[r2:MH1_APPLIED_TO]-(acl:MH1_ACL)-[r3:MH1_HAS_RULE]->(rule:MH1_ACLRule)
        \\RETURN fw, r1, iface, r2, acl, r3, rule LIMIT 10
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should find the path: fw -> iface <- acl -> rule
    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 7);
}

// GAP-0425: Test 5-hop traversal to prevent regression
test "GAP-0425: 5-hop deep chain traversal" {
    const allocator = testing.allocator;
    const context = try makeContext();
    const store = graph_store.getGlobalStore(allocator);

    // Create a 6-node chain: A -> B -> C -> D -> E -> F
    const labels = try makeLabels(allocator, &.{"MH2_Node"});
    defer freeLabels(allocator, labels);

    var node_ids: [6]u64 = undefined;
    for (&node_ids, 0..) |*id, i| {
        id.* = try store.createNode(labels);
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "node_{d}", .{i}) catch "node";
        try store.setNodeProperty(id.*, "name", .{ .String = name });
    }

    // Create edges: A->B, B->C, C->D, D->E, E->F
    for (0..5) |i| {
        _ = try store.createEdge(node_ids[i], node_ids[i + 1], "MH2_CONNECTS");
    }

    const query =
        \\MATCH (a:MH2_Node)-[r1:MH2_CONNECTS]->(b:MH2_Node)-[r2:MH2_CONNECTS]->(c:MH2_Node)-[r3:MH2_CONNECTS]->(d:MH2_Node)-[r4:MH2_CONNECTS]->(e:MH2_Node)-[r5:MH2_CONNECTS]->(f:MH2_Node)
        \\RETURN a, b, c, d, e, f LIMIT 10
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should find the single path through the chain
    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 6);
}

// GAP-0425: Test 7-hop traversal to stress-test the fix
test "GAP-0425: 7-hop deep chain traversal" {
    const allocator = testing.allocator;
    const context = try makeContext();
    const store = graph_store.getGlobalStore(allocator);

    // Create an 8-node chain: N0 -> N1 -> ... -> N7
    const labels = try makeLabels(allocator, &.{"MH3_Deep"});
    defer freeLabels(allocator, labels);

    var node_ids: [8]u64 = undefined;
    for (&node_ids, 0..) |*id, i| {
        id.* = try store.createNode(labels);
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "d_{d}", .{i}) catch "d";
        try store.setNodeProperty(id.*, "idx", .{ .Int = @intCast(i) });
        try store.setNodeProperty(id.*, "name", .{ .String = name });
    }

    for (0..7) |i| {
        _ = try store.createEdge(node_ids[i], node_ids[i + 1], "MH3_LINK");
    }

    const query =
        \\MATCH (n0:MH3_Deep)-[r0:MH3_LINK]->(n1:MH3_Deep)-[r1:MH3_LINK]->(n2:MH3_Deep)-[r2:MH3_LINK]->(n3:MH3_Deep)-[r3:MH3_LINK]->(n4:MH3_Deep)-[r4:MH3_LINK]->(n5:MH3_Deep)-[r5:MH3_LINK]->(n6:MH3_Deep)-[r6:MH3_LINK]->(n7:MH3_Deep)
        \\RETURN n0, n1, n2, n3, n4, n5, n6, n7 LIMIT 10
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 8);
}

// GAP-0425: Test multi-hop with many bindings (fan-out pattern)
test "GAP-0425: multi-hop with high fan-out does not exhaust arena" {
    const allocator = testing.allocator;
    const context = try makeContext();
    const store = graph_store.getGlobalStore(allocator);

    // Create a fan-out topology: root -> 10 mid nodes -> 5 leaf nodes each
    const root_labels = try makeLabels(allocator, &.{"MH4_Root"});
    defer freeLabels(allocator, root_labels);
    const mid_labels = try makeLabels(allocator, &.{"MH4_Mid"});
    defer freeLabels(allocator, mid_labels);
    const leaf_labels = try makeLabels(allocator, &.{"MH4_Leaf"});
    defer freeLabels(allocator, leaf_labels);

    const root = try store.createNode(root_labels);
    try store.setNodeProperty(root, "name", .{ .String = "root" });

    // Create 10 mid nodes connected to root
    var mid_ids: [10]u64 = undefined;
    for (&mid_ids, 0..) |*mid, i| {
        mid.* = try store.createNode(mid_labels);
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "mid_{d}", .{i}) catch "mid";
        try store.setNodeProperty(mid.*, "name", .{ .String = name });
        _ = try store.createEdge(root, mid.*, "MH4_HAS_CHILD");
    }

    // Create 5 leaf nodes per mid node (50 total)
    for (mid_ids) |mid| {
        for (0..5) |j| {
            const leaf = try store.createNode(leaf_labels);
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "leaf_{d}", .{j}) catch "leaf";
            try store.setNodeProperty(leaf, "name", .{ .String = name });
            _ = try store.createEdge(mid, leaf, "MH4_HAS_LEAF");
        }
    }

    // 2-hop fan-out query: root -> mid -> leaf (should produce 50 results)
    const query =
        \\MATCH (r:MH4_Root)-[e1:MH4_HAS_CHILD]->(m:MH4_Mid)-[e2:MH4_HAS_LEAF]->(l:MH4_Leaf)
        \\RETURN r, m, l
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // 10 mid * 5 leaf = 50 results expected
    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 3);
}

// GAP-0425: Test multi-hop with mixed directions
test "GAP-0425: multi-hop with mixed left/right directions" {
    const allocator = testing.allocator;
    const context = try makeContext();
    const store = graph_store.getGlobalStore(allocator);

    const labels = try makeLabels(allocator, &.{"MH5_N"});
    defer freeLabels(allocator, labels);

    // Create: A -[FORWARD]-> B <-[BACKWARD]- C -[FORWARD]-> D
    const a = try store.createNode(labels);
    try store.setNodeProperty(a, "name", .{ .String = "A" });
    const b = try store.createNode(labels);
    try store.setNodeProperty(b, "name", .{ .String = "B" });
    const c = try store.createNode(labels);
    try store.setNodeProperty(c, "name", .{ .String = "C" });
    const d = try store.createNode(labels);
    try store.setNodeProperty(d, "name", .{ .String = "D" });

    _ = try store.createEdge(a, b, "MH5_FORWARD");
    _ = try store.createEdge(c, b, "MH5_BACKWARD"); // C -> B (traversed as B <- C)
    _ = try store.createEdge(c, d, "MH5_FORWARD");

    const query =
        \\MATCH (a:MH5_N)-[r1:MH5_FORWARD]->(b:MH5_N)<-[r2:MH5_BACKWARD]-(c:MH5_N)-[r3:MH5_FORWARD]->(d:MH5_N)
        \\RETURN a, b, c, d
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should find: A -> B <- C -> D
    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 4);
}

// GAP-0425: Test multi-hop with anonymous intermediate nodes
test "GAP-0425: multi-hop with anonymous intermediate nodes" {
    const allocator = testing.allocator;
    const context = try makeContext();
    const store = graph_store.getGlobalStore(allocator);

    const labels = try makeLabels(allocator, &.{"MH6_X"});
    defer freeLabels(allocator, labels);

    // Create chain: start -> mid1 -> mid2 -> end
    const start = try store.createNode(labels);
    try store.setNodeProperty(start, "name", .{ .String = "start" });
    const mid1 = try store.createNode(labels);
    try store.setNodeProperty(mid1, "name", .{ .String = "mid1" });
    const mid2 = try store.createNode(labels);
    try store.setNodeProperty(mid2, "name", .{ .String = "mid2" });
    const end_node = try store.createNode(labels);
    try store.setNodeProperty(end_node, "name", .{ .String = "end" });

    _ = try store.createEdge(start, mid1, "MH6_STEP");
    _ = try store.createEdge(mid1, mid2, "MH6_STEP");
    _ = try store.createEdge(mid2, end_node, "MH6_STEP");

    // Use anonymous intermediate nodes (only name start and end)
    const query =
        \\MATCH (s:MH6_X)-[:MH6_STEP]->(:MH6_X)-[:MH6_STEP]->(:MH6_X)-[:MH6_STEP]->(e:MH6_X)
        \\RETURN s, e
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should find: start -> (anon) -> (anon) -> end
    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 2);
}
