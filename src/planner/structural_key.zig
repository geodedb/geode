const std = @import("std");
const planner_root = @import("../planner.zig");

// Structural key derivation for query graph patterns. This intentionally
// ignores variable names and focuses on: chain count, hop sequence, left/right
// node label multisets (sorted), relationship direction, variable-length
// quantifier bounds, and inline property predicate sets. Property VALUE
// literals are ignored (normalizing across constant differences); we encode
// a sorted '+'-joined list of property KEYS (or empty) for each node endpoint
// instead of just a count. This sharpens collision resistance while remaining
// compact. This provides a canonical signature for
// reusing cached path pattern expansions.
//
// Format (BNF-ish):
//   key := 'c' <chain_count> '|' chain { '||' chain }*
//   chain := hop { ';' hop }*
//   hop := 'L[' labels ']P[' prop_keys ']' 'D' <dir> 'Q' <min> ',' <max> 'R[' labels ']P[' prop_keys ']'
//   labels := label { '+' label }*   -- labels sorted lexicographically
//   prop_keys := key { '+' key }*     -- property keys sorted; empty if none
//   <dir> one of '>' '<' '-'
//   <min>/<max>: decimal integers; '*' for unbounded (null)
// Example: single hop (a:Person {name:"Alice"})-[:T*1..3]->(b:Animal)
//   c1|L[Person]P1D>Q1,3R[Animal]P0
//
// NOTE: This is a skeleton and will evolve as more structural features matter
// (e.g., degree buckets, predicate selectivity classes, property key ordering
// beyond counts). Keeping it compact aids cache key locality.

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeyEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDifferentiation; OWNER=planner; UPDATED=2025-09-21
pub fn deriveStructuralKey(allocator: std.mem.Allocator, q: planner_root.ast.Query) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const writer = buf.writer();
    try writer.print("c{d}|", .{q.match.chains.len});
    for (q.match.chains, 0..) |chain, ci| {
        if (ci != 0) try writer.writeAll("||");
        for (chain.hops, 0..) |hop, hi| {
            if (hi != 0) try writer.writeByte(';');
            // Left node labels
            try writer.writeAll("L[");
            try writeSortedLabels(writer, hop.left.labels);
            try writer.writeAll("]P[");
            try writeSortedPropKeys(writer, hop.left.props);
            try writer.writeByte(']');
            // Relationship direction + quantifier
            try writer.writeAll("D");
            try writer.writeByte(directionChar(hop.rel.dir));
            try writer.writeAll("Q");
            try writeQuant(writer, hop.rel.min_len);
            try writer.writeByte(',');
            try writeQuant(writer, hop.rel.max_len);
            // Right node
            try writer.writeAll("R[");
            try writeSortedLabels(writer, hop.right.labels);
            try writer.writeAll("]P[");
            try writeSortedPropKeys(writer, hop.right.props);
            try writer.writeByte(']');
        }
    }
    return buf.toOwnedSlice();
}

fn writeSortedPropKeys(writer: anytype, props: ?[]planner_root.ast.Property) !void {
    if (props == null or props.?.len == 0) return; // empty set
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const arr = props.?;
    var tmp = try al.alloc([]const u8, arr.len);
    for (arr, 0..) |p, i| tmp[i] = p.key;
    std.sort.sort([]const u8, tmp, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (tmp, 0..) |k, i| {
        if (i != 0) try writer.writeByte('+');
        try writer.writeAll(k);
    }
}

fn directionChar(dir: planner_root.ast.RelDir) u8 {
    return switch (dir) {
        .right => '>',
        .left => '<',
        .undirected => '-',
    };
}

fn writeQuant(writer: anytype, q: ?u32) !void {
    if (q) |v| try writer.print("{d}", .{v}) else try writer.writeByte('*');
}

fn writeSortedLabels(writer: anytype, labels: [][]const u8) !void {
    if (labels.len == 0) return; // empty
    // Copy to temporary slice for sorting
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const al = arena_allocator.allocator();
    var tmp = try al.alloc([]const u8, labels.len);
    for (labels, 0..) |lab, i| tmp[i] = lab;
    std.sort.sort([]const u8, tmp, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (tmp, 0..) |lab, i| {
        if (i != 0) try writer.writeByte('+');
        try writer.writeAll(lab);
    }
}
