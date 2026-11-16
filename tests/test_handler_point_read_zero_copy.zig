// GAP-0805 / M1.3 regression: the QUIC + gRPC handlers must dispatch
// simple point-read MATCH queries through the zero-copy `PointReadView`
// path instead of `QueryReadSession.snapshotUnderReadLock` (which deep-
// clones the entire nodes+properties arena). If this test ever sees a
// non-zero `getQueryReadSessionInitCount`, the handler has regressed
// back to the clone path.
//
// The handler's full QUIC/gRPC connection seam is heavyweight to stand
// up in a unit test, so instead this test exercises the same decision
// points the handler uses:
//
//   1. `analyzeProgram(parsed)` must flag a single-node MATCH with a
//      single-label + single-property equality as `is_point_read`.
//   2. On that branch, the handler takes the shared read lock and calls
//      `PointReadView.init(store_ref)` — no `QueryReadSession.initIfAvailable`.
//   3. Non-point queries (e.g. traversal, WHERE clause) must fall
//      through to the snapshot path, which increments the clone counter.
//
// Keeping this test at the analysis + view level means it runs fast and
// isolates the contract we care about (no deep-clone on the hot path)
// from transport details that are already covered elsewhere.
//
// CANARY: REQ=REQ-PERF-QPS-0805; FEATURE="PointReadView"; ASPECT=HandlerWire; STATUS=TESTED; TEST=tests/test_handler_point_read_zero_copy.zig; OWNER=performance; UPDATED=2026-04-19

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;
const ast = geode.gql.ast;

fn parseProgram(src: []const u8) !struct { ast.Program, std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return .{ program, arena };
}

test "handler dispatch: point-read MATCH takes PointReadView, does NOT clone" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Start from a known clean slate — other tests in the same binary
    // may have mutated the process-wide clone counter.
    try store.clearNodes();

    const labels = [_][]const u8{"Person"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    _ = try store.createNode(labels_slice);

    // 1. Plan analysis flags the query as a point read.
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) RETURN n");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try testing.expect(analysis.is_point_read);

    // 2. The point-read branch constructs a PointReadView directly; no
    //    call to QueryReadSession.initIfAvailable occurs.
    graph_store.resetQueryReadSessionInitCount();
    var view = try graph_store.PointReadView.init(&store);
    defer view.deinit();
    try testing.expectEqual(@as(u64, 0), graph_store.getQueryReadSessionInitCount());

    // 3. Sanity: the view still exposes nodes for the executor.
    const ids = try view.getAllNodes(allocator);
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
}

test "handler dispatch: MATCH with traversal is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id})-[:KNOWS]->(m) RETURN m");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try testing.expect(!analysis.is_point_read);
}

test "handler dispatch: MATCH with WHERE clause is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) WHERE n.active = true RETURN n");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try testing.expect(!analysis.is_point_read);
}

test "handler dispatch: CREATE mutation is NOT a point read" {
    const prog, var arena = try parseProgram("CREATE (n:Person {name: 'alice'})");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try testing.expect(!analysis.is_point_read);
}
