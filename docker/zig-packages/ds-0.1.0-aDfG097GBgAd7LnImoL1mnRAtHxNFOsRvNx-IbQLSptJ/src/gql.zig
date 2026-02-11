// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const Vertex = @import("graph_core.zig").Vertex;

/// GQL emission result containing query string and parameters
pub const GQLResult = struct {
    query: []const u8,
    params: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *GQLResult) void {
        self.allocator.free(self.query);
        var it = self.params.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
    }
};

/// Emit ISO-GQL flavored CREATE clauses for all vertices and edges
/// Each node is emitted as (n<ID>:Node {id: $nid_<ID>}) and edges as (nA)-[:REL]->(nB)
/// Deterministic ordering: vertex IDs sorted, edges sorted by (srcID, dstID)
pub fn emitCreateGQL(comptime T: type, graph: *Graph(T), allocator: Allocator) !GQLResult {
    // Get and sort vertices by ID
    const vertices = graph.vertices.items;
    const sorted_vertices = try allocator.alloc(*Vertex(T), vertices.len);
    defer allocator.free(sorted_vertices);
    @memcpy(sorted_vertices, vertices);

    std.mem.sort(*Vertex(T), sorted_vertices, {}, struct {
        fn lessThan(_: void, a: *Vertex(T), b: *Vertex(T)) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    var query: std.ArrayListUnmanaged(u8) = .{};
    errdefer query.deinit(allocator);

    var params = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    // Always start with CREATE
    try query.appendSlice(allocator, "CREATE ");

    // Emit nodes
    for (sorted_vertices, 0..) |vertex, i| {
        if (i > 0) {
            try query.appendSlice(allocator, ", ");
        }

        const vid = vertex.id;
        const sanitized_vid = try sanitizeID(vid, allocator);
        defer allocator.free(sanitized_vid);

        const alias = try std.fmt.allocPrint(allocator, "n{s}", .{sanitized_vid});
        defer allocator.free(alias);

        const pid = try std.fmt.allocPrint(allocator, "nid_{s}", .{sanitized_vid});
        const vid_copy = try allocator.dupe(u8, vid);

        try params.put(pid, vid_copy);

        try query.writer(allocator).print("({s}:Node {{id: ${s}}})", .{ alias, pid });
    }

    // Get and sort edges
    const edges = graph.edges.items;
    var edge_keys: std.ArrayListUnmanaged(EdgeKey) = .{};
    defer edge_keys.deinit(allocator);

    for (edges) |edge| {
        const verts = edge.getVertices();
        try edge_keys.append(allocator, .{
            .src = verts[0].id,
            .dst = verts[1].id,
        });
    }

    std.mem.sort(EdgeKey, edge_keys.items, {}, struct {
        fn lessThan(_: void, a: EdgeKey, b: EdgeKey) bool {
            const src_cmp = std.mem.order(u8, a.src, b.src);
            if (src_cmp == .lt) return true;
            if (src_cmp == .gt) return false;
            return std.mem.order(u8, a.dst, b.dst) == .lt;
        }
    }.lessThan);

    // Emit edges
    const edge_op = if (graph.directed) "-[:REL]->" else "-[:REL]-";
    for (edge_keys.items) |key| {
        const sanitized_src = try sanitizeID(key.src, allocator);
        defer allocator.free(sanitized_src);
        const src_alias = try std.fmt.allocPrint(allocator, "n{s}", .{sanitized_src});
        defer allocator.free(src_alias);

        const sanitized_dst = try sanitizeID(key.dst, allocator);
        defer allocator.free(sanitized_dst);
        const dst_alias = try std.fmt.allocPrint(allocator, "n{s}", .{sanitized_dst});
        defer allocator.free(dst_alias);

        try query.writer(allocator).print("\nCREATE ({s}){s}({s})", .{ src_alias, edge_op, dst_alias });
    }

    return GQLResult{
        .query = try query.toOwnedSlice(allocator),
        .params = params,
        .allocator = allocator,
    };
}

/// Emit MATCH query for shortest path between two node IDs using variable length pattern
/// Deterministic ordering by relying solely on bound parameters
pub fn emitMatchShortestPathGQL(start_id: []const u8, end_id: []const u8, allocator: Allocator) !GQLResult {
    if (start_id.len == 0 or end_id.len == 0) {
        return error.EmptyID;
    }

    const query_str = "MATCH (s:Node {id: $sid}), (t:Node {id: $tid}), p = shortestPath((s)-[:REL*..]->(t)) RETURN p";
    const query = try allocator.dupe(u8, query_str);
    errdefer allocator.free(query);

    var params = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    const sid_key = try allocator.dupe(u8, "sid");
    const sid_value = try allocator.dupe(u8, start_id);
    try params.put(sid_key, sid_value);

    const tid_key = try allocator.dupe(u8, "tid");
    const tid_value = try allocator.dupe(u8, end_id);
    try params.put(tid_key, tid_value);

    return GQLResult{
        .query = query,
        .params = params,
        .allocator = allocator,
    };
}

/// Sanitize ID for use in GQL aliases and parameter names
/// Keep alphanumeric only; replace others with underscore
pub fn sanitizeID(id: []const u8, allocator: Allocator) ![]const u8 {
    if (id.len == 0) {
        return allocator.dupe(u8, "_");
    }

    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(allocator);

    for (id) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '_');
        }
    }

    if (result.items.len == 0) {
        return allocator.dupe(u8, "_");
    }

    return result.toOwnedSlice(allocator);
}

const EdgeKey = struct {
    src: []const u8,
    dst: []const u8,
};
