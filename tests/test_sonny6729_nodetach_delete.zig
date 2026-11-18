// SONNY-6729 regression: `NODETACH DELETE` parses and is a plain DELETE.
//
// ISO/IEC 39075:2024 13.5: <delete statement> ::= [ DETACH | NODETACH ] DELETE
// <delete item list>, and SR 6: a statement that names neither is NODETACH.
// `MATCH (a:A) NODETACH DELETE a` was a parse error ("expected token 'RETURN',
// got 'identifier'": NODETACH read as an alias). It now behaves as DELETE: a
// node with an edge left is refused (NodeHasEdges, G1001), one without is
// deleted, and a relationship is deleted.
//
// Real parser, executor and store; no mocks.
//
// CANARY: REQ=REQ-SONNY-6729-NODETACH-DELETE; FEATURE="DeleteStatement"; ASPECT=Nodetach; STATUS=TESTED; TEST=tests/test_sonny6729_nodetach_delete.zig; OWNER=engine; UPDATED=2026-11-17

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
        _ = try self.exec("CREATE (:A {k: 9})");
    }
};

test "SONNY-6729: NODETACH DELETE of a node with an edge is refused like DELETE" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    inline for (.{
        "MATCH (a:A {k: 1}) NODETACH DELETE a",
        "match (a:A {k: 1}) nodetach delete a",
        "MATCH (a:A {k: 1}) SET a.touched = 1 NODETACH DELETE a",
    }) |q| {
        try testing.expectError(error.NodeHasEdges, h.exec(q));
    }
    try testing.expectEqual(@as(i64, 2), try h.count("MATCH (a:A) RETURN count(*) AS c"));
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH ()-[r:R]->() RETURN count(*) AS c"));
}

test "SONNY-6729: NODETACH DELETE deletes a node with no edge and a relationship" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    _ = try h.exec("MATCH (a:A {k: 9}) NODETACH DELETE a");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (a:A) RETURN count(*) AS c"));
    _ = try h.exec("MATCH (:A)-[r:R]->(:B) NODETACH DELETE r");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH ()-[r:R]->() RETURN count(*) AS c"));
    // The edge is gone, so the node now deletes.
    _ = try h.exec("MATCH (a:A {k: 1}) NODETACH DELETE a");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (a:A) RETURN count(*) AS c"));
}

test "SONNY-6729: DETACH DELETE and DELETE are unchanged" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    try testing.expectError(error.NodeHasEdges, h.exec("MATCH (a:A {k: 1}) DELETE a"));
    _ = try h.exec("MATCH (a:A {k: 1}) DETACH DELETE a");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH ()-[r:R]->() RETURN count(*) AS c"));
}

test "SONNY-6729: a variable named like a clause word is still an alias elsewhere" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seed();
    // NODETACH is reserved (ISO 21.3), so it cannot be a variable: refused,
    // not read as NODETACH.
    try testing.expectError(error.UnexpectedToken, h.exec("MATCH (nodetach:A) RETURN nodetach"));
}
