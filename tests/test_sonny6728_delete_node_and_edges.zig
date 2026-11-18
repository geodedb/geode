// SONNY-6728 regression: a node is deleted without DETACH when every edge it
// has is deleted by the same statement.
//
// ISO/IEC 39075:2024 13.5 <delete statement> GR 4, 5 and 7: the statement
// collects NODES and EDGES over all the records of the working table, and only
// then raises G1001 (dependent object error, edges still exist) for a node in
// NODES with a connected edge that is not in EDGES; then every member of EDGES
// and NODES is deleted. `MATCH (a:A)-[r:R]->(b:B) DELETE r, a, b` was refused
// with NodeHasEdges because each node was checked against the store before any
// edge went. A node whose edge the statement leaves, or a statement that names
// the nodes but not the edge, is still refused, and nothing is deleted.
//
// Real parser, executor and store; no mocks.
//
// CANARY: REQ=REQ-SONNY-6728-DELETE-NODE-AND-EDGES; FEATURE="DeleteStatement"; ASPECT=EdgesDeletedWithNode; STATUS=TESTED; TEST=tests/test_sonny6728_delete_node_and_edges.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init() !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .session = execution.SessionState.init(testing.allocator),
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn count(self: *Harness, query: []const u8) !i64 {
        const res = try self.exec(query);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return switch (res.rows[0][0]) {
            .Int => |i| i,
            else => error.NotAnInteger,
        };
    }

    fn seed(self: *Harness) !void {
        _ = try self.exec("CREATE (:A {k: 1})-[:R]->(:B {k: 2})");
    }

    fn nodes(self: *Harness) !i64 {
        return self.count("MATCH (n) RETURN count(*) AS c");
    }

    fn edges(self: *Harness) !i64 {
        return self.count("MATCH ()-[r]->() RETURN count(*) AS c");
    }
};

test "SONNY-6728: DELETE r, a, b deletes the edge and both nodes, in any item order" {
    inline for (.{
        "MATCH (a:A)-[r:R]->(b:B) DELETE r, a, b",
        "MATCH (a:A)-[r:R]->(b:B) DELETE a, b, r",
        "MATCH (a:A)-[r:R]->(b:B) NODETACH DELETE b, r, a",
        "MATCH (a:A)-[r:R]->(b:B) WHERE a.k = 1 DELETE r, a, b",
    }) |q| {
        var h = try Harness.init();
        defer h.deinit();
        try h.seed();
        _ = h.exec(q) catch |err| {
            std.debug.print("{s}: {s}\n", .{ q, @errorName(err) });
            return err;
        };
        try testing.expectEqual(@as(i64, 0), try h.nodes());
        try testing.expectEqual(@as(i64, 0), try h.edges());
    }
}

test "SONNY-6728: DELETE r, a deletes the edge and one end, and the other end stays" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    _ = try h.exec("MATCH (a:A)-[r:R]->(b:B) DELETE r, a");
    try testing.expectEqual(@as(i64, 1), try h.nodes());
    try testing.expectEqual(@as(i64, 0), try h.edges());
}

test "SONNY-6728: a node with several edges, all deleted by the statement, is deleted" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.exec("CREATE (a:A {k: 1}), (a)-[:R]->(:B {k: 2}), (a)-[:R]->(:B {k: 3}), (:B {k: 4})-[:R]->(a)");
    try testing.expectEqual(@as(i64, 3), try h.edges());
    // Three rows, one per edge: EDGES is the union over the rows.
    _ = try h.exec("MATCH (a:A)-[r:R]-(b:B) DELETE r, a");
    try testing.expectEqual(@as(i64, 0), try h.edges());
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (a:A) RETURN count(*) AS c"));
    try testing.expectEqual(@as(i64, 3), try h.count("MATCH (b:B) RETURN count(*) AS c"));
}

test "SONNY-6728: a path is deleted with its nodes and edges" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    _ = try h.exec("MATCH p = (a:A)-[:R]->(b:B) DELETE p");
    try testing.expectEqual(@as(i64, 0), try h.nodes());
    try testing.expectEqual(@as(i64, 0), try h.edges());
}

test "SONNY-6728: a node with an edge the statement leaves is refused and nothing is deleted" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    _ = try h.exec("MATCH (a:A) CREATE (a)-[:S]->(:C {k: 5})");
    try testing.expectEqual(@as(i64, 2), try h.edges());
    // r (:R) goes with a, but a's :S edge stays.
    try testing.expectError(error.NodeHasEdges, h.exec("MATCH (a:A)-[r:R]->(b:B) DELETE r, a"));
    try testing.expectEqual(@as(i64, 2), try h.edges());
    try testing.expectEqual(@as(i64, 3), try h.nodes());
    // b has only r: r, b is fine.
    _ = try h.exec("MATCH (a:A)-[r:R]->(b:B) DELETE r, b");
    try testing.expectEqual(@as(i64, 1), try h.edges());
    try testing.expectEqual(@as(i64, 2), try h.nodes());
}

test "SONNY-6728: naming the nodes without the edge is still refused" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    try testing.expectError(error.NodeHasEdges, h.exec("MATCH (a:A)-[r:R]->(b:B) DELETE a, b"));
    try testing.expectError(error.NodeHasEdges, h.exec("MATCH (a:A)-[r:R]->(b:B) NODETACH DELETE a"));
    try testing.expectEqual(@as(i64, 2), try h.nodes());
    try testing.expectEqual(@as(i64, 1), try h.edges());
}

test "SONNY-6728: a DELETE after a SET deletes the edge and its nodes too" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    _ = try h.exec("MATCH (a:A)-[r:R]->(b:B) SET a.seen = 1 DELETE r, a, b");
    try testing.expectEqual(@as(i64, 0), try h.nodes());
    try testing.expectEqual(@as(i64, 0), try h.edges());
}

test "SONNY-6728: DETACH DELETE still takes the edges of a node" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    _ = try h.exec("MATCH (a:A)-[r:R]->(b:B) DETACH DELETE a, b");
    try testing.expectEqual(@as(i64, 0), try h.nodes());
    try testing.expectEqual(@as(i64, 0), try h.edges());
}
