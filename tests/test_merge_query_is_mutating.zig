// KNOWN BUG #2 (from-dump EDGE phase) — root-cause regression #1.
//
// A `MATCH ... MERGE ...` statement parses into a single `.Query` AST node with
// `q.merge_statement != null` (NOT a top-level `.Merge` statement). The QUIC
// transport handler decides whether to take the exclusive WRITE lock (cheap,
// live store) or the shared READ-snapshot path (which DEEP-CLONES the entire
// graph — `snapshotUnderReadLock` / `QueryReadSession.initIfAvailable`) by
// calling `query_traits.isMutatingStatement` → `isQueryMutating`.
//
// `isQueryMutating` checked create_pattern / set_clauses / remove_clauses /
// delete_items but NOT `merge_statement`. So the from-dump edge statement
//
//     MATCH (a:Taxon {source, source_id}), (b:Taxon {source, source_id})
//     MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = ?
//
// was classified NON-mutating → the handler took the read path → it deep-cloned
// ALL nodes (O(graph)) BEFORE running the MERGE. At 14.27M taxa that clone
// dominated CPU (~43% in perf), pinned the server, and the edge phase created
// ~0 edges while the client backpressured. (Confirmed by perf: the dominant
// frame was `graph_store.snapshotUnderReadLock`.)
//
// The fix adds `q.merge_statement != null` to `isQueryMutating`, so a
// MATCH...MERGE takes the write-lock path (no deep clone) — matching the intent
// documented in crud_operations.executeMerge ("MERGE already executes under the
// graph write lock; an adapter-backed QueryReadSession would clone the entire
// graph once per statement").
//
// CANARY: REQ=REQ-PERF-MERGE-NO-SNAPSHOT-CLONE; FEATURE="MergeStatementIsMutating"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_merge_query_is_mutating.zig; OWNER=performance; UPDATED=2026-06-21

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const query_traits = geode.query_traits;
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;
const ast = geode.gql.ast;

fn parseProgram(src: []const u8) !struct { ast.Program, std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return .{ program, arena };
}

// The exact from-dump edge-phase statement shape.
const EDGE_STMT =
    "MATCH (a:Taxon {source: 'col', source_id: 'P'}), (b:Taxon {source: 'col', source_id: 'C'}) " ++
    "MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = 'run1'";

test "MATCH...MERGE relationship statement is classified as mutating" {
    var parsed = try parseProgram(EDGE_STMT);
    defer parsed[1].deinit();
    const program = parsed[0];

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = &program.statements[0];

    // Sanity: it parsed as a Query carrying a merge_statement (not a .Merge stmt).
    try testing.expect(stmt.* == .Query);
    try testing.expect(stmt.Query.merge_statement != null);

    // The fix: this MUST be mutating so the handler takes the write-lock path
    // and skips the O(graph) QueryReadSession deep-clone. Before the fix
    // isQueryMutating ignored merge_statement and returned false here.
    try testing.expect(query_traits.isQueryMutating(&stmt.Query));
    try testing.expect(query_traits.isMutatingStatement(stmt));
    try testing.expect(query_traits.isMutatingProgram(&program));
}

test "plain node MERGE (MATCH...MERGE node) is mutating" {
    var parsed = try parseProgram("MATCH (a:Taxon {source_id: 'X'}) MERGE (a)-[r:SELF]->(a)");
    defer parsed[1].deinit();
    const stmt = &parsed[0].statements[0];
    try testing.expect(stmt.* == .Query);
    try testing.expect(query_traits.isMutatingStatement(stmt));
}

test "a pure read MATCH...RETURN is still NOT mutating (no false positive)" {
    var parsed = try parseProgram("MATCH (a:Taxon {source_id: 'X'}), (b:Taxon {source_id: 'Y'}) RETURN a, b");
    defer parsed[1].deinit();
    const stmt = &parsed[0].statements[0];
    try testing.expect(stmt.* == .Query);
    try testing.expect(stmt.Query.merge_statement == null);
    // Must stay read-only so genuine reads keep their snapshot/streaming path.
    try testing.expect(!query_traits.isMutatingStatement(stmt));
    try testing.expect(!query_traits.isMutatingProgram(&parsed[0]));
}
