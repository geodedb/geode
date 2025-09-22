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
//   hop := 'L[' labels ']P[' prop_keys ']V[' value_shape ']S' <sel_left> 'DB' <deg_left> 'D' <dir> 'Q' <min> ',' <max> 'R[' labels ']P[' prop_keys ']V[' value_shape ']S' <sel_right> 'DB' <deg_right>
//   labels := label { '+' label }*   -- labels sorted lexicographically
//   prop_keys := key { '+' key }*     -- property keys sorted; empty if none
//   value_shape := class { '+' class }* -- value shape classes (N,S,B,U,A,O) sorted unique per side
//   <dir> one of '>' '<' '-'
//   <min>/<max>: decimal integers; '*' for unbounded (null)
// Example: single hop (a:Person {name:"Alice"})-[:T*1..3]->(b:Animal)
//   c1|L[Person]P1D>Q1,3R[Animal]P0
//
// NOTE: This is a skeleton and will evolve as more structural features matter
// (e.g., degree buckets, predicate selectivity classes, property key ordering
// beyond counts). Keeping it compact aids cache key locality.

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeyEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDifferentiation; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeyValueShapeEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyValueShapeDifferentiation; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeySelectivityEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeySelectivityClassEncoding; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeyDegreeBucketEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDegreeBucketEncoding; OWNER=planner; UPDATED=2025-09-21
pub fn deriveStructuralKey(allocator: std.mem.Allocator, q: planner_root.ast.Query) ![]u8 {
    // First pass: accumulate approximate degree counts per named node across all chains.
    // Anonymous (null name) nodes are treated as unique per occurrence (degree=1 unless reused explicitly).
    var degree_map = std.StringHashMap(usize).init(allocator);
    defer degree_map.deinit();
    for (q.match.chains) |chain| {
        for (chain.hops) |hop| {
            if (hop.left.name) |lname| {
                const gop = try degree_map.getOrPut(lname);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            if (hop.right.name) |rname| {
                const gop2 = try degree_map.getOrPut(rname);
                if (!gop2.found_existing) gop2.value_ptr.* = 0;
                gop2.value_ptr.* += 1;
            }
        }
    }

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
            try writer.writeAll("]V[");
            try writeValueShape(writer, hop.left.props);
            try writer.writeByte(']');
            // Selectivity class for left node
            try writer.writeAll("S");
            try writer.writeByte(selectivityClass(hop.left.props));
            // Degree bucket (derived from occurrence count in pattern). Anonymous nodes -> degree 1 (L)
            const ldeg: usize = if (hop.left.name) |lname| degree_map.get(lname) orelse 1 else 1;
            try writer.writeAll("DB");
            try writer.writeByte(degreeBucketClass(ldeg));
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
            try writer.writeAll("]V[");
            try writeValueShape(writer, hop.right.props);
            try writer.writeByte(']');
            try writer.writeAll("S");
            try writer.writeByte(selectivityClass(hop.right.props));
            const rdeg: usize = if (hop.right.name) |rname| degree_map.get(rname) orelse 1 else 1;
            try writer.writeAll("DB");
            try writer.writeByte(degreeBucketClass(rdeg));
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

fn writeValueShape(writer: anytype, props: ?[]planner_root.ast.Property) !void {
    if (props == null or props.?.len == 0) return; // empty
    // Collect shape classes into fixed bool set
    var have = [6]bool{ false, false, false, false, false, false }; // N,S,B,U,A,O
    for (props.?) |p| {
        if (p.value) |expr_ptr| {
            const expr = expr_ptr.*;
            const cls_index = switch (expr) {
                .Int, .Decimal => 0, // N
                .String => 1, // S
                .Bool => 2, // B
                .Null => 3, // U
                .Array => 4, // A
                else => 5, // O (object / other / map / complex)
            };
            have[cls_index] = true;
        }
    }
    const codes = [_]u8{ 'N', 'S', 'B', 'U', 'A', 'O' };
    var first = true;
    var i: usize = 0;
    while (i < have.len) : (i += 1) {
        if (have[i]) {
            if (!first) {
                try writer.writeByte('+');
            } else {
                first = false;
            }
            try writer.writeByte(codes[i]);
        }
    }
}

fn selectivityClass(props: ?[]planner_root.ast.Property) u8 {
    if (props == null) return 'Z';
    const len = props.?.len;
    return if (len == 0) 'Z' else if (len == 1) 'L' else if (len <= 3) 'M' else 'H';
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

fn degreeBucketClass(deg: usize) u8 {
    // Bucket mapping: 0 -> 'Z', 1 -> 'L', 2-3 -> 'M', 4+ -> 'H'
    return if (deg == 0) 'Z' else if (deg == 1) 'L' else if (deg <= 3) 'M' else 'H';
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
