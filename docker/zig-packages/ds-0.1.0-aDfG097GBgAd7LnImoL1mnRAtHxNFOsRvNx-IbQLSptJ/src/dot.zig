// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const Vertex = @import("graph_core.zig").Vertex;
const createEdge = @import("graph_core.zig").createEdge;
const EdgeOptions = @import("graph_core.zig").EdgeOptions;

/// DOT graph representation with attributes
/// Supports parsing and serializing graphs in DOT format
pub const DOTGraph = struct {
    graph: *Graph([]const u8),
    allocator: Allocator,
    strict: bool = false,
    // Attribute maps: node_id -> {key -> value}
    node_attrs: std.StringHashMap(std.StringHashMap([]const u8)),
    // Edge attributes: "src\x00dst" -> {key -> value}
    edge_attrs: std.StringHashMap(std.StringHashMap([]const u8)),

    pub fn init(allocator: Allocator, graph: *Graph([]const u8)) !DOTGraph {
        return DOTGraph{
            .graph = graph,
            .allocator = allocator,
            .node_attrs = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .edge_attrs = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *DOTGraph) void {
        // Free node attributes
        var node_it = self.node_attrs.iterator();
        while (node_it.next()) |entry| {
            var attr_map = entry.value_ptr.*;
            var attr_it = attr_map.iterator();
            while (attr_it.next()) |attr| {
                self.allocator.free(attr.key_ptr.*);
                self.allocator.free(attr.value_ptr.*);
            }
            attr_map.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.node_attrs.deinit();

        // Free edge attributes
        var edge_it = self.edge_attrs.iterator();
        while (edge_it.next()) |entry| {
            var attr_map = entry.value_ptr.*;
            var attr_it = attr_map.iterator();
            while (attr_it.next()) |attr| {
                self.allocator.free(attr.key_ptr.*);
                self.allocator.free(attr.value_ptr.*);
            }
            attr_map.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.edge_attrs.deinit();
    }

    /// Parse DOT format from a reader
    pub fn unmarshal(allocator: Allocator, reader: anytype) !DOTGraph {
        const graph = try allocator.create(Graph([]const u8));
        graph.* = Graph([]const u8).init(allocator);

        var dot_graph = try DOTGraph.init(allocator, graph);
        errdefer dot_graph.deinit();

        // Read all input
        const max_size = 1024 * 1024; // 1MB limit
        const content = try reader.readAllAlloc(allocator, max_size);
        defer allocator.free(content);

        // Parse the content
        try dot_graph.parse(content);

        return dot_graph;
    }

    /// Parse DOT format from string
    fn parse(self: *DOTGraph, content: []const u8) !void {
        var lines: std.ArrayListUnmanaged([]const u8) = .{};
        defer lines.deinit(self.allocator);

        // Split into lines and trim
        var iter = std.mem.tokenizeAny(u8, content, "\n\r");
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0) {
                try lines.append(self.allocator, trimmed);
            }
        }

        // Check for strict mode
        if (lines.items.len > 0 and std.mem.startsWith(u8, lines.items[0], "strict ")) {
            self.strict = true;
        }

        // Detect directed/undirected
        for (lines.items) |line| {
            if (std.mem.indexOf(u8, line, "digraph") != null) {
                self.graph.directed = true;
                break;
            } else if (std.mem.indexOf(u8, line, "graph") != null) {
                break;
            }
        }

        // Track vertices we've seen
        var vertex_map = std.StringHashMap(*Vertex([]const u8)).init(self.allocator);
        defer vertex_map.deinit();

        // Parse edges and nodes
        for (lines.items) |line| {
            // Skip braces only
            if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;

            // Remove graph/digraph prefix if present (for single-line input)
            var line_content = line;
            if (std.mem.indexOf(u8, line, "{")) |brace_pos| {
                // Extract content after the opening brace
                const after_brace = line[brace_pos + 1 ..];
                // Remove trailing brace if present
                if (std.mem.lastIndexOf(u8, after_brace, "}")) |close_pos| {
                    line_content = std.mem.trim(u8, after_brace[0..close_pos], " \t");
                } else {
                    line_content = std.mem.trim(u8, after_brace, " \t");
                }
            } else if (std.mem.startsWith(u8, line, "graph ") or std.mem.startsWith(u8, line, "digraph ") or std.mem.startsWith(u8, line, "strict ")) {
                // Skip pure declaration lines without braces
                continue;
            }

            if (line_content.len == 0) continue;

            // Try to parse as edge
            const arrow = if (self.graph.directed) "->" else "--";
            if (std.mem.indexOf(u8, line_content, arrow)) |_| {
                try self.parseEdge(line_content, arrow, &vertex_map);
            } else if (std.mem.indexOf(u8, line_content, "\"") != null) {
                // Try to parse as standalone node
                try self.parseNode(line_content, &vertex_map);
            }
        }
    }

    fn parseNode(self: *DOTGraph, line: []const u8, vertex_map: *std.StringHashMap(*Vertex([]const u8))) !void {
        // Parse: "id" [attrs]
        var start: ?usize = null;
        var end: ?usize = null;

        for (line, 0..) |c, i| {
            if (c == '"') {
                if (start == null) {
                    start = i + 1;
                } else if (end == null) {
                    end = i;
                    break;
                }
            }
        }

        if (start == null or end == null or end.? <= start.?) return;

        const node_id = line[start.?..end.?];

        // Create vertex if not exists
        if (!vertex_map.contains(node_id)) {
            // Note: initWithId duplicates the ID internally, so pass the raw string
            // Use empty string for value since []const u8 values aren't freed by Vertex
            const vertex = try Vertex([]const u8).initWithId(self.allocator, node_id, "");
            try vertex_map.put(vertex.id, vertex); // Use the owned ID from vertex
            self.graph.addVertex(vertex);
        }

        // Parse attributes if present
        if (std.mem.indexOf(u8, line[end.?..], "[")) |bracket_start| {
            const attr_start = end.? + bracket_start;
            if (std.mem.indexOf(u8, line[attr_start..], "]")) |bracket_end| {
                const attrs_str = line[attr_start + 1 .. attr_start + bracket_end];
                try self.parseAndStoreNodeAttrs(node_id, attrs_str);
            }
        }
    }

    fn parseEdge(self: *DOTGraph, line: []const u8, arrow: []const u8, vertex_map: *std.StringHashMap(*Vertex([]const u8))) !void {
        const arrow_pos = std.mem.indexOf(u8, line, arrow) orelse return;

        // Extract source and dest IDs (between quotes)
        const src_id = try self.extractQuotedId(line[0..arrow_pos]);
        const dest_id = try self.extractQuotedId(line[arrow_pos + arrow.len ..]);

        if (src_id.len == 0 or dest_id.len == 0) return;

        // Create vertices if they don't exist
        if (!vertex_map.contains(src_id)) {
            // Note: initWithId duplicates the ID internally, so pass the raw string
            const vertex = try Vertex([]const u8).initWithId(self.allocator, src_id, "");
            try vertex_map.put(vertex.id, vertex);
            self.graph.addVertex(vertex);
        }

        if (!vertex_map.contains(dest_id)) {
            const vertex = try Vertex([]const u8).initWithId(self.allocator, dest_id, "");
            try vertex_map.put(vertex.id, vertex);
            self.graph.addVertex(vertex);
        }

        const src_vertex = vertex_map.get(src_id).?;
        const dest_vertex = vertex_map.get(dest_id).?;

        // Create edge
        const opts = EdgeOptions{
            .directed = self.graph.directed,
            .weighted = false,
            .weight = 0,
        };
        const edge = try createEdge([]const u8, self.allocator, src_vertex, dest_vertex, "", opts);
        self.graph.addEdge(edge);

        // Parse edge attributes if present
        const after_dest = line[arrow_pos + arrow.len ..];
        if (std.mem.indexOf(u8, after_dest, "[")) |bracket_start| {
            if (std.mem.indexOf(u8, after_dest[bracket_start..], "]")) |bracket_len| {
                const attrs_str = after_dest[bracket_start + 1 .. bracket_start + bracket_len];
                const edge_key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ src_id, dest_id });
                try self.parseAndStoreEdgeAttrs(edge_key, attrs_str);
            }
        }
    }

    fn extractQuotedId(_: *DOTGraph, text: []const u8) ![]const u8 {
        var start: ?usize = null;
        var end: ?usize = null;

        for (text, 0..) |c, i| {
            if (c == '"') {
                if (start == null) {
                    start = i + 1;
                } else {
                    end = i;
                    break;
                }
            }
        }

        if (start != null and end != null and end.? > start.?) {
            return text[start.?..end.?];
        }

        return "";
    }

    fn parseAndStoreNodeAttrs(self: *DOTGraph, node_id: []const u8, attrs_str: []const u8) !void {
        const attrs = try self.parseAttrList(attrs_str);
        const id_copy = try self.allocator.dupe(u8, node_id);
        try self.node_attrs.put(id_copy, attrs);
    }

    fn parseAndStoreEdgeAttrs(self: *DOTGraph, edge_key: []const u8, attrs_str: []const u8) !void {
        const attrs = try self.parseAttrList(attrs_str);
        try self.edge_attrs.put(edge_key, attrs);
    }

    fn parseAttrList(self: *DOTGraph, s: []const u8) !std.StringHashMap([]const u8) {
        var attrs = std.StringHashMap([]const u8).init(self.allocator);
        errdefer attrs.deinit();

        // Split by comma or space
        var iter = std.mem.tokenizeAny(u8, s, ", \t");
        while (iter.next()) |token| {
            if (std.mem.indexOf(u8, token, "=")) |eq_pos| {
                const key = std.mem.trim(u8, token[0..eq_pos], " \t");
                var value = std.mem.trim(u8, token[eq_pos + 1 ..], " \t");

                // Remove quotes from value
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }

                if (key.len > 0) {
                    const key_copy = try self.allocator.dupe(u8, key);
                    const value_copy = try self.allocator.dupe(u8, value);
                    try attrs.put(key_copy, value_copy);
                }
            }
        }

        return attrs;
    }

    /// Serialize graph to DOT format
    pub fn marshal(self: *DOTGraph, writer: anytype) !void {
        const kind = if (self.graph.directed) "digraph" else "graph";
        const op = if (self.graph.directed) "->" else "--";

        // Write header
        if (self.strict) {
            try writer.print("strict {s} {{\n", .{kind});
        } else {
            try writer.print("{s} {{\n", .{kind});
        }

        // Collect isolated nodes (nodes not in any edge)
        var edge_nodes = std.StringHashMap(void).init(self.allocator);
        defer edge_nodes.deinit();

        for (self.graph.edges.items) |edge| {
            const vertices = edge.getVertices();
            try edge_nodes.put(vertices[0].id, {});
            try edge_nodes.put(vertices[1].id, {});
        }

        // Write isolated nodes first (sorted)
        var isolated: std.ArrayListUnmanaged([]const u8) = .{};
        defer isolated.deinit(self.allocator);

        for (self.graph.vertices.items) |vertex| {
            if (!edge_nodes.contains(vertex.id)) {
                try isolated.append(self.allocator, vertex.id);
            }
        }

        std.mem.sort([]const u8, isolated.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (isolated.items) |id| {
            if (self.node_attrs.get(id)) |attrs| {
                try writer.print("\"{s}\" {s}\n", .{ id, try self.formatAttrList(attrs) });
            } else {
                try writer.print("\"{s}\"\n", .{id});
            }
        }

        // Write edges (sorted for canonical output)
        var edge_lines: std.ArrayListUnmanaged(EdgeLine) = .{};
        defer edge_lines.deinit(self.allocator);

        // Collect all edges
        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            // Free all keys added to seen
            var key_it = seen.keyIterator();
            while (key_it.next()) |k| {
                self.allocator.free(k.*);
            }
            seen.deinit();
        }

        for (self.graph.edges.items) |edge| {
            const vertices = edge.getVertices();
            var src = vertices[0].id;
            var dst = vertices[1].id;

            // For undirected graphs, normalize edge order
            if (!self.graph.directed) {
                if (std.mem.order(u8, src, dst) == .gt) {
                    const tmp = src;
                    src = dst;
                    dst = tmp;
                }
            }

            // Skip if strict mode and we've seen this edge
            const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ src, dst });
            defer self.allocator.free(key);

            if (self.strict) {
                if (seen.contains(key)) continue;
                try seen.put(try self.allocator.dupe(u8, key), {});
            }

            const edge_key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ vertices[0].id, vertices[1].id });
            const attrs = self.edge_attrs.get(edge_key);
            self.allocator.free(edge_key);

            try edge_lines.append(self.allocator, .{
                .src = src,
                .dst = dst,
                .attrs = attrs,
            });
        }

        // Sort edges
        std.mem.sort(EdgeLine, edge_lines.items, {}, struct {
            fn lessThan(_: void, a: EdgeLine, b: EdgeLine) bool {
                const src_cmp = std.mem.order(u8, a.src, b.src);
                if (src_cmp == .lt) return true;
                if (src_cmp == .gt) return false;
                return std.mem.order(u8, a.dst, b.dst) == .lt;
            }
        }.lessThan);

        // Write edges
        for (edge_lines.items) |edge_line| {
            if (edge_line.attrs) |attrs| {
                const attr_str = try self.formatAttrList(attrs);
                defer self.allocator.free(attr_str);
                try writer.print("\"{s}\" {s} \"{s}\" {s}\n", .{ edge_line.src, op, edge_line.dst, attr_str });
            } else {
                try writer.print("\"{s}\" {s} \"{s}\"\n", .{ edge_line.src, op, edge_line.dst });
            }
        }

        try writer.writeAll("}");
    }

    fn formatAttrList(self: *DOTGraph, attrs: std.StringHashMap([]const u8)) ![]const u8 {
        var keys: std.ArrayListUnmanaged([]const u8) = .{};
        defer keys.deinit(self.allocator);

        var iter = attrs.iterator();
        while (iter.next()) |entry| {
            try keys.append(self.allocator, entry.key_ptr.*);
        }

        // Sort keys for canonical output
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        var result: std.ArrayListUnmanaged(u8) = .{};
        errdefer result.deinit(self.allocator);

        try result.append(self.allocator, '[');
        for (keys.items, 0..) |key, i| {
            if (i > 0) try result.append(self.allocator, ' ');
            const value = attrs.get(key).?;
            const escaped = try self.escapeAttr(value);
            defer self.allocator.free(escaped);
            const formatted = try std.fmt.allocPrint(self.allocator, "{s}=\"{s}\"", .{ key, escaped });
            defer self.allocator.free(formatted);
            try result.appendSlice(self.allocator, formatted);
        }
        try result.append(self.allocator, ']');

        return result.toOwnedSlice(self.allocator);
    }

    fn escapeAttr(self: *DOTGraph, value: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .{};
        errdefer result.deinit(self.allocator);

        for (value) |c| {
            if (c == '"') {
                try result.appendSlice(self.allocator, "\\\"");
            } else {
                try result.append(self.allocator, c);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

const EdgeLine = struct {
    src: []const u8,
    dst: []const u8,
    attrs: ?std.StringHashMap([]const u8),
};
