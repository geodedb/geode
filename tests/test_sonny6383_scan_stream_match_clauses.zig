// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6383 item 1: since 0df2ad6a the parser records every MATCH clause in
// `ast.Query.match_clauses`, and the fast paths' field allowlists
// (`write_shape.onlyFields`) did not name the field, so no parsed MATCH could
// take the engine-direct node scan stream (`node_scan_stream.zig`) or the
// bulk MATCH ... CREATE / MATCH ... MERGE edge paths (`bulk_ingest.zig`).
//
// These tests drive the real parser, the real stream (`prepare` +
// `buildNextPage`) and the real executor over a persisted store:
//   - a simple MATCH is served by the stream (asserted, not inferred from the
//     rows), and the stream's rows equal the executor's;
//   - shapes the stream cannot serve (OPTIONAL MATCH, a second MATCH clause,
//     a clause record that does not describe the single MATCH) are refused;
//   - the bulk edge fast paths classify their MATCH shapes again.
//
// CANARY: REQ=REQ-SONNY-6383-STREAM-MATCH-CLAUSES; FEATURE="NodeScanStream"; ASPECT=MatchClauseGate; STATUS=TESTED; TEST=tests/test_sonny6383_scan_stream_match_clauses.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const node_scan_stream = geode.node_scan_stream;
const bulk_ingest = geode.bulk_ingest;
const ast = geode.gql.ast;

const N_NODES: i64 = 40;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        _ = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn seed(self: *Harness) !void {
        const aa = self.arena.allocator();
        var i: i64 = 0;
        while (i < N_NODES) : (i += 1) {
            const k = if (@mod(i, 4) == 0) "x" else "y";
            const q = try std.fmt.allocPrint(aa, "CREATE (:A {{i: {d}, k: '{s}'}})", .{ i, k });
            var r = try self.run(q);
            r.deinit(aa);
        }
        // Nodes of another label the stream must not return.
        var j: i64 = 0;
        while (j < 5) : (j += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:B {{i: {d}, k: 'x'}})", .{1000 + j});
            var r = try self.run(q);
            r.deinit(aa);
        }
    }
};

fn parseQueryAst(arena: *std.heap.ArenaAllocator, src: []const u8) !*const ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

fn lessI64(_: void, a: i64, b: i64) bool {
    return a < b;
}

/// The first column of every row as an integer, sorted (the stream reads in
/// slot order, the executor in its own: compare as multisets).
fn sortedFirstColumn(allocator: std.mem.Allocator, rows: anytype) ![]i64 {
    const out = try allocator.alloc(i64, rows.len);
    for (rows, 0..) |row, idx| out[idx] = row[0].Int;
    std.mem.sort(i64, out, {}, lessI64);
    return out;
}

/// Serve `src` through the engine-direct stream; error.NotServedByStream when
/// it declines. Returns the first column of every row, sorted.
fn streamColumn(h: *Harness, src: []const u8) ![]i64 {
    const aa = h.arena.allocator();
    const q = try parseQueryAst(&h.arena, src);
    if (!node_scan_stream.isEligible(q, null)) return error.NotServedByStream;
    var stream = (try node_scan_stream.prepare(aa, q, h.ctx, &.{}, &.{}, &.{})) orelse return error.NotServedByStream;
    defer stream.deinit();
    var values: std.ArrayList(i64) = .empty;
    while (true) {
        var page = try stream.buildNextPage(aa, 7);
        defer page.result.deinit(aa);
        for (page.result.rows) |row| try values.append(aa, row[0].Int);
        if (page.final) break;
    }
    std.mem.sort(i64, values.items, {}, lessI64);
    return values.items;
}

fn executorColumn(h: *Harness, src: []const u8) ![]i64 {
    const aa = h.arena.allocator();
    var res = try h.run(src);
    defer res.deinit(aa);
    return sortedFirstColumn(aa, res.rows);
}

test "SONNY-6383: a simple MATCH is served by the node scan stream and agrees with the executor" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    const shapes = [_][]const u8{
        "MATCH (n:A) RETURN n.i AS i",
        "MATCH (n:A) WHERE n.i >= 30 RETURN n.i AS i",
        "MATCH (n:A {k: 'x'}) RETURN n.i AS i",
        "MATCH (n:A) WHERE n.k = 'x' RETURN count(n) AS c",
        "MATCH (n:A) RETURN count(*) AS c",
        "MATCH (n:A) FILTER n.i < 3 RETURN n.i AS i",
    };
    for (shapes) |src| {
        const streamed = streamColumn(&h, src) catch |err| {
            std.debug.print("SONNY-6383: not served by the stream: {s} ({s})\n", .{ src, @errorName(err) });
            return err;
        };
        const executed = try executorColumn(&h, src);
        testing.expectEqualSlices(i64, executed, streamed) catch |err| {
            std.debug.print("SONNY-6383: stream and executor differ for {s}\n", .{src});
            return err;
        };
    }
    // The values themselves, so an empty pair cannot pass.
    try testing.expectEqualSlices(i64, &.{ 30, 31, 32, 33, 34, 35, 36, 37, 38, 39 }, try streamColumn(&h, "MATCH (n:A) WHERE n.i >= 30 RETURN n.i AS i"));
    try testing.expectEqualSlices(i64, &.{10}, try streamColumn(&h, "MATCH (n:A {k: 'x'}) RETURN count(n) AS c"));
}

test "SONNY-6383: the stream refuses MATCH shapes it cannot serve" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    const refused = [_][]const u8{
        "OPTIONAL MATCH (n:A) RETURN n.i AS i",
        "MATCH (n:A) MATCH (m:B) RETURN n.i AS i",
        "MATCH (n:A) WHERE n.i > 1 MATCH (m:B) WHERE m.i < 3 RETURN n.i AS i",
        "MATCH (n:A) OPTIONAL MATCH (n)-[:R]->(m) RETURN n.i AS i",
    };
    for (refused) |src| {
        try testing.expectError(error.NotServedByStream, streamColumn(&h, src));
    }
}

test "SONNY-6383: a clause record that is not the single plain MATCH is refused" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();
    const aa = h.arena.allocator();

    const parsed = try parseQueryAst(&h.arena, "MATCH (n:A) WHERE n.i > 1 RETURN n.i AS i");
    // The parser's own record of the single MATCH is accepted.
    try testing.expectEqual(@as(usize, 1), parsed.match_clauses.len);
    try testing.expect(node_scan_stream.isEligible(parsed, null));

    const optional_clause = [_]ast.MatchClause{.{ .optional = true, .end = 1, .where = parsed.where_clause }};
    const short_clause = [_]ast.MatchClause{.{ .optional = false, .end = 0 }};
    const two_clauses = [_]ast.MatchClause{ .{ .optional = false, .end = 1 }, .{ .optional = true, .end = 1, .where = parsed.where_clause } };
    const records = [_][]const ast.MatchClause{ &optional_clause, &short_clause, &two_clauses };
    for (records) |record| {
        var q = parsed.*;
        q.match_clauses = record;
        try testing.expect(!node_scan_stream.isEligible(&q, null));
        try testing.expect((try node_scan_stream.prepare(aa, &q, h.ctx, &.{}, &.{}, &.{})) == null);
    }
}

fn parseProgram(arena: *std.heap.ArenaAllocator, src: []const u8) !ast.Program {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    return p.parseProgram();
}

test "SONNY-6383: the bulk MATCH ... CREATE and MATCH ... MERGE edge paths classify a parsed MATCH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var create_edge = try parseProgram(&arena, "MATCH (a:W {node_id: 'a'}), (b:G {node_id: 'b'}) CREATE (a)-[:L]->(b)");
    try testing.expectEqual(bulk_ingest.BulkPattern.match_create_edge, bulk_ingest.matchSingleStatement(&create_edge));

    var merge_edge = try parseProgram(&arena, "MATCH (a:W {node_id: 'a'}), (b:G {node_id: 'b'}) MERGE (a)-[r:L]->(b)");
    try testing.expectEqual(bulk_ingest.BulkPattern.match_merge_edge, bulk_ingest.matchSingleStatement(&merge_edge));

    // Two plain MATCH clauses are the same join as one MATCH with a comma.
    var two_clause_create = try parseProgram(&arena, "MATCH (a:W {node_id: 'a'}) MATCH (b:G {node_id: 'b'}) CREATE (a)-[:L]->(b)");
    try testing.expectEqual(bulk_ingest.BulkPattern.match_create_edge, bulk_ingest.matchSingleStatement(&two_clause_create));

    // An OPTIONAL MATCH keeps the record when it matches nothing: not this path.
    var optional_create = try parseProgram(&arena, "MATCH (a:W {node_id: 'a'}) OPTIONAL MATCH (b:G {node_id: 'b'}) CREATE (a)-[:L]->(b)");
    try testing.expect(bulk_ingest.matchSingleStatement(&optional_create) != .match_create_edge);
}
