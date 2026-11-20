// SONNY-3357 regression: a relationship MERGE matches on the relationship's
// property map too.
//
// MERGE is a Geode extension (ISO/IEC 39075:2024 has no MERGE statement);
// its semantics follow openCypher: the WHOLE pattern must match, the
// relationship's properties included, or the pattern is created. The edge
// a relationship MERGE bound was looked up by endpoints, type, graph and
// tenant only (`findExistingEdge`), so
//   MERGE (a)-[:T {w: 1}]->(b)  then  MERGE (a)-[:T {w: 2}]->(b)
// left ONE edge (w = 1) and bound it for the second MERGE's ON MATCH SET.
//
// Pinned on the executor's standalone MERGE and its MATCH ... MERGE (one
// MERGE per matched row), and on the server's MATCH ... MERGE edge fast path,
// which never compared relationship properties either: it now declines such
// a statement to the executor (`bulk_ingest.matchMergeEdgeSpec`).
//
// Real executor, store and adapter; no mocks.
//
// CANARY: REQ=REQ-SONNY-3357-MERGE-REL-PROPS; FEATURE="MergeRelationship"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3357_merge_relationship_properties.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const bulk_ingest = geode.bulk_ingest;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.NoAdapter;
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
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

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn cell(self: *Harness, query: []const u8) ![]const u8 {
        const res = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1 or res.rows[0].len < 1) {
            std.debug.print("{s}: {d} rows\n", .{ query, res.rows.len });
            return error.UnexpectedRows;
        }
        const aa = self.arena.allocator();
        return switch (res.rows[0][0]) {
            .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
            .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
            .Null => "null",
            else => |v| try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
        };
    }

    fn expectCell(self: *Harness, query: []const u8, want: []const u8) !void {
        const got = try self.cell(query);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: expected {s}, got {s}\n", .{ query, want, got });
            return error.WrongAnswer;
        }
    }
};

test "SONNY-3357: a standalone relationship MERGE creates an edge whose properties differ" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("MERGE (a:A {k: 1})-[:T {w: 1}]->(b:B {k: 2})");
    try h.run("MERGE (a:A {k: 1})-[:T {w: 2}]->(b:B {k: 2})");
    try h.expectCell("MATCH (:A)-[r:T]->(:B) RETURN count(r) AS c", "2");
    try h.expectCell("MATCH (:A)-[r:T {w: 2}]->(:B) RETURN count(r) AS c", "1");
    // The same properties again: matched, nothing created.
    try h.run("MERGE (a:A {k: 1})-[:T {w: 1}]->(b:B {k: 2})");
    try h.expectCell("MATCH (:A)-[r:T]->(:B) RETURN count(r) AS c", "2");
    // No property in the pattern: any edge of the type matches.
    try h.run("MERGE (a:A {k: 1})-[:T]->(b:B {k: 2})");
    try h.expectCell("MATCH (:A)-[r:T]->(:B) RETURN count(r) AS c", "2");
    try h.expectCell("MATCH (n) RETURN count(n) AS c", "2");
}

test "SONNY-3357: ON MATCH SET runs on the edge whose properties match, ON CREATE SET on a new one" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE (:A {k: 1}), (:B {k: 2})");
    try h.run("MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T {w: 1}]->(b) ON CREATE SET r.c = 1 ON MATCH SET r.m = 1");
    try h.run("MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T {w: 2}]->(b) ON CREATE SET r.c = 2 ON MATCH SET r.m = 2");
    try h.expectCell("MATCH (:A)-[r:T]->(:B) RETURN count(r) AS c", "2");
    try h.expectCell("MATCH (:A)-[r:T {w: 2}]->(:B) RETURN r.c AS c", "2");
    try h.expectCell("MATCH (:A)-[r:T {w: 1}]->(:B) RETURN r.m AS m", "null");
    try h.run("MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T {w: 1}]->(b) ON CREATE SET r.c = 3 ON MATCH SET r.m = 3");
    try h.expectCell("MATCH (:A)-[r:T]->(:B) RETURN count(r) AS c", "2");
    try h.expectCell("MATCH (:A)-[r:T {w: 1}]->(:B) RETURN r.m AS m", "3");
    try h.expectCell("MATCH (:A)-[r:T {w: 2}]->(:B) RETURN r.m AS m", "null");
    // A property the edge lacks does not match it.
    try h.run("MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T {w: 1, x: 9}]->(b)");
    try h.expectCell("MATCH (:A)-[r:T]->(:B) RETURN count(r) AS c", "3");
}

fn parse(arena: *std.heap.ArenaAllocator, src: []const u8) !geode.gql.ast.Program {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    return p.parseProgram();
}

test "SONNY-3357: the server's MATCH ... MERGE edge fast path declines a relationship with properties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    {
        var program = try parse(&arena,
            \\MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T {w: 1}]->(b)
        );
        try testing.expect(bulk_ingest.matchSingleStatement(&program) != .match_merge_edge);
        try testing.expect(bulk_ingest.matchMergeEdgeSpec(&program) == null);
    }
    {
        var program = try parse(&arena,
            \\MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T {w: $w}]->(b) SET r.run = 'x'
        );
        try testing.expect(bulk_ingest.matchMergeEdgeSpec(&program) == null);
    }
    // Control: no relationship property, a bare SET: still the fast path.
    {
        var program = try parse(&arena,
            \\MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T]->(b) SET r.run = 'x'
        );
        try testing.expectEqual(bulk_ingest.BulkPattern.match_merge_edge, bulk_ingest.matchSingleStatement(&program));
    }
}
