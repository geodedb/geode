const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;

/// Seed `count` LT_Person nodes with properties {lt_id: i, name: "LT_Person_i", age: 20 + (i % 50)}.
/// Matches the shape used by geode-test-harness's batchCreateNodes so bench results compare
/// directly against loadtest baselines.
pub fn seedPerson(allocator: std.mem.Allocator, graph_name: []const u8, count: usize) !void {
    const store = graph_store.getWritableGlobalStore(allocator);
    const labels: []const []const u8 = &.{"LT_Person"};
    var name_buf: [64]u8 = undefined;
    for (0..count) |i| {
        const node_id = try store.createNodeWithGraph(labels, graph_name);
        try store.setNodeProperty(node_id, "lt_id", .{ .Int = @intCast(i) });
        const name = try std.fmt.bufPrint(&name_buf, "LT_Person_{d}", .{i});
        try store.setNodeProperty(node_id, "name", .{ .String = name });
        try store.setNodeProperty(node_id, "age", .{ .Int = 20 + @as(i64, @intCast(i % 50)) });
    }
}

/// Seed `nodes` LT_Person + `edges_per_node` outgoing LT_KNOWS edges per node.
/// Targets follow the loadtest's round-robin: node i → (i + 1 + k * 7) % nodes for k in [0, edges_per_node).
pub fn seedPersonKnowsGraph(allocator: std.mem.Allocator, graph_name: []const u8, nodes: usize, edges_per_node: usize) !void {
    try seedPerson(allocator, graph_name, nodes);
    const store = graph_store.getWritableGlobalStore(allocator);
    const stride: usize = 7;
    for (0..nodes) |i| {
        for (0..edges_per_node) |k| {
            const target_idx = (i + 1 + k * stride) % nodes;
            var src_id: u64 = undefined;
            var tgt_id: u64 = undefined;
            if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(i) }, &src_id) != .found) return error.SeedFailed;
            if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(target_idx) }, &tgt_id) != .found) return error.SeedFailed;
            _ = try store.createEdgeWithGraph(src_id, tgt_id, "LT_KNOWS", graph_name);
        }
    }
}

/// Seed fan-out: `persons` LT_Person + `companies` LT_Company + `knows_per_person` LT_KNOWS
/// + 1 LT_WORKS_AT person→company per person.
pub fn seedFanOut(allocator: std.mem.Allocator, graph_name: []const u8, persons: usize, companies: usize, knows_per_person: usize) !void {
    try seedPersonKnowsGraph(allocator, graph_name, persons, knows_per_person);
    const store = graph_store.getWritableGlobalStore(allocator);
    const labels: []const []const u8 = &.{"LT_Company"};
    var name_buf: [64]u8 = undefined;
    for (0..companies) |i| {
        const cid = try store.createNodeWithGraph(labels, graph_name);
        try store.setNodeProperty(cid, "lt_id", .{ .Int = @intCast(i) });
        const name = try std.fmt.bufPrint(&name_buf, "Company_{d}", .{i});
        try store.setNodeProperty(cid, "name", .{ .String = name });
    }
    for (0..persons) |i| {
        const company_idx = i % companies;
        var src_id: u64 = undefined;
        var tgt_id: u64 = undefined;
        if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(i) }, &src_id) != .found) return error.SeedFailed;
        if (store.lookupMergeCandidate(graph_name, "LT_Company", "lt_id", .{ .Int = @intCast(company_idx) }, &tgt_id) != .found) return error.SeedFailed;
        _ = try store.createEdgeWithGraph(src_id, tgt_id, "LT_WORKS_AT", graph_name);
    }
}
