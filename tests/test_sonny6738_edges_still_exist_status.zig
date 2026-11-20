// SONNY-6738: a DELETE of a node that still has edges answers GQLSTATUS G1001.
//
// ISO/IEC 39075:2024 13.5 GR 5 raises "dependent object error - edges still
// exist" (G1001; 23.1 Table 8, class G1) for a node the statement deletes that
// keeps an edge. NodeHasEdges had no entry in `proto_util.mapError` and fell
// through to the generic 58000 (system error: "the server broke"), though a
// client's statement caused it. It is now G1001 on both transports (both read
// `mapError`), with the human text kept (it names the edges).
//
// Real parser, executor and store, and the error table both transports use.
//
// CANARY: REQ=REQ-SONNY-6738-G1001-EDGES-STILL-EXIST; FEATURE="ErrorMapping"; ASPECT=DependentObjectError; STATUS=TESTED; TEST=tests/test_sonny6738_edges_still_exist_status.zig; OWNER=server; UPDATED=2026-11-18

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
};

fn expectG1001(err: anyerror) !void {
    const info = geode.proto_util.mapError(err);
    try testing.expectEqualStrings("G1001", info.code);
    try testing.expect(std.mem.indexOf(u8, info.message, "edges") != null);
}

test "SONNY-6738: NodeHasEdges maps to G1001, not 58000" {
    try expectG1001(error.NodeHasEdges);
}

test "SONNY-6738: DELETE and NODETACH DELETE of a connected node fail with the G1001 error" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.exec("CREATE (:A {k: 1})-[:R]->(:B {k: 2})");
    inline for (.{
        "MATCH (a:A) DELETE a",
        "MATCH (a:A) NODETACH DELETE a",
        "MATCH (a:A)-[r:R]->(b:B) DELETE a, b",
    }) |q| {
        const err = if (h.exec(q)) |_| return error.ExpectedRefusal else |e| e;
        try expectG1001(err);
    }
}
