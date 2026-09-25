// SONNY-2687 regression (part 2): the expression path read other graphs.
//
// Pattern comprehensions, COUNT {}, EXISTS {} and shortestPath() are
// evaluated in graph_algorithms.zig, whose node scans walk `store.nodes`, the
// nodes of EVERY graph, and whose hops never checked the graph of the node or
// edge they reached. A session bound to graph "default" therefore read,
// counted and found graph "g2"'s nodes (probe P4 of the SONNY-2679 review):
// `RETURN [(h:Doc) | h.s]` returned a g2 node, COUNT {} counted it and
// EXISTS {} found it.
//
// The expression path now resolves the session's graph once, as knn() does,
// and every node it scans, starts from, reaches or puts on a path, and every
// edge it walks, must be in that graph. (Part 1, the transport post-filter
// looking inside lists and maps, is tested in src/server/rls_filter.zig.)
//
// Fixture, all in one in-memory store so a malformed cross-graph edge can be
// written:
//   graph "default": (:G {s: 'g1'}) -R-> (:Doc {s: 'here'})
//                    g1 -R-> otherg   (an edge tagged "default" whose target
//                                      lives in g2: corrupt data, which the
//                                      graph check on a hop target must stop)
//   graph "g2":      (:Doc {s: 'otherg'}), (:Doc {s: 'x2'}) -R-> (:Doc {s: 'y2'})
//
// CANARY: REQ=REQ-SONNY-2687-GRAPH-SCOPE; FEATURE="ExpressionPathGraphScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2687_expression_graph_scope.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const Session = struct {
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn init() !Session {
        const allocator = testing.allocator;
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() != null) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    fn seed(self: *Session) !void {
        try self.exec("CREATE (:G {s: 'g1'})");
        try self.exec("MATCH (g:G {s: 'g1'}) CREATE (g)-[:R]->(:Doc {s: 'here'})");

        const store = graph_store.getGlobalStore(testing.allocator);
        const doc = [_][]const u8{"Doc"};
        const otherg = try store.createNodeWithGraph(&doc, "g2");
        try store.setNodeProperty(otherg, "s", .{ .String = "otherg" });
        const x2 = try store.createNodeWithGraph(&doc, "g2");
        try store.setNodeProperty(x2, "s", .{ .String = "x2" });
        const y2 = try store.createNodeWithGraph(&doc, "g2");
        try store.setNodeProperty(y2, "s", .{ .String = "y2" });
        _ = try store.createEdgeWithGraph(x2, y2, "R", "g2");

        // The corrupt cross-graph edge: tagged "default", target in g2.
        const g1 = try idOf("g1");
        _ = try store.createEdgeWithGraph(g1, otherg, "R", graph_store.DEFAULT_GRAPH_NAME);
    }
};

fn idOf(s: []const u8) !u64 {
    const store = graph_store.getGlobalStore(testing.allocator);
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.properties.get("s")) |pv| {
            if (pv == .String and std.mem.eql(u8, pv.String, s)) return entry.key_ptr.*;
        }
    }
    return error.NodeNotFound;
}

fn nodeName(n: *const graph_store.Node) []const u8 {
    if (n.properties.get("s")) |pv| {
        if (pv == .String) return pv.String;
    }
    return "?";
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .Node => |n| try std.fmt.allocPrint(aa, "({s})", .{nodeName(n)}),
        .Path => |p| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(aa, "p(");
            for (p.nodes, 0..) |n, i| {
                if (i > 0) try out.append(aa, '>');
                try out.appendSlice(aa, nodeName(n));
            }
            try out.append(aa, ')');
            break :blk try out.toOwnedSlice(aa);
        },
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *part| part.* = try render(aa, item);
            std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ",", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, aa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(aa, try std.fmt.allocPrint(aa, fmt, args));
    }
};

fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query) catch |err| {
        try f.add(aa, "{s}: error {s}", .{ query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        const want_text = try std.mem.join(aa, ",", exp);
        const got_text = try std.mem.join(aa, ",", got);
        try f.add(aa, "{s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ query, exp.len, want_text, got.len, got_text });
    }
}

test "SONNY-2687: pattern comprehensions, COUNT {}, EXISTS {} and shortestPath() stay in the session's graph" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    // Node scans.
    try expectRows(&s, &f, "RETURN [(h:Doc) | h.s] AS xs", &.{"[here]"});
    try expectRows(&s, &f, "MATCH (g:G) RETURN [(h:Doc) | h.s] AS xs", &.{"[here]"});
    try expectRows(&s, &f, "RETURN COUNT { (h:Doc) } AS c", &.{"1"});
    try expectRows(&s, &f, "RETURN EXISTS { (h:Doc {s: 'otherg'}) } AS e", &.{"false"});
    try expectRows(&s, &f, "RETURN EXISTS { (h:Doc {s: 'here'}) } AS e", &.{"true"});
    // A walk that starts from another graph's node.
    try expectRows(&s, &f, "RETURN [(a:Doc {s: 'x2'})-[:R]->(b) | b.s] AS xs", &.{"[]"});
    try expectRows(&s, &f, "RETURN shortestPath((a:Doc {s: 'x2'})-[*]-(b:Doc {s: 'y2'})) AS p", &.{"null"});
    // A hop whose target is in another graph (the corrupt cross-graph edge).
    try expectRows(&s, &f, "MATCH (g:G) RETURN [(g)-[:R]->(h) | h.s] AS xs", &.{"[here]"});
    try expectRows(&s, &f, "MATCH (g:G) RETURN COUNT { (g)-[:R]->() } AS c", &.{"1"});
    try expectRows(&s, &f, "MATCH (g:G) RETURN COUNT { (g)-[:R*1..2]->() } AS c", &.{"1"});
    try expectRows(&s, &f, "MATCH (g:G) RETURN EXISTS { (g)-[:R]->(h {s: 'otherg'}) } AS e", &.{"false"});
    // The MATCH path already stays in the graph (control).
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{"here"});
    try expectRows(&s, &f, "MATCH (h:Doc) RETURN h.s", &.{"here"});

    if (f.items.items.len != 0) {
        std.debug.print("\n{d} failed check(s):\n", .{f.items.items.len});
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.ExpressionPathLeftTheGraph;
    }
}
