// CANARY: REQ=REQ-QUIC-HC-017; FEATURE="CountFastPath"; ASPECT=EffectfulPreambleGate; STATUS=TESTED; TEST=tests/test_gap0892_count_pushdown_preamble.zig; OWNER=execution; UPDATED=2026-06-11
//
// GAP-0892 regression: the QUIC handler's count-pushdown fast path (and the
// node-scan streaming fast path) execute ONLY `analysis.target`. For a
// multi-statement program like
//
//     SESSION SET PROPERTY GRAPH "G1";
//     MATCH (n) RETURN count(*) AS c
//
// that meant the count was evaluated against the request-start session graph
// and the SESSION SET statement's side effects were silently dropped —
// gql_conformance T11/T12/T14 returned c=0 while the row-iterating path over
// the same graph returned correct data (the regular executor runs the whole
// program in order).
//
// The fix adds `ProgramAnalysis.has_effectful_preamble`: true iff the program
// contains any statement other than the fast-path target and bare transaction
// control. Handler fast paths bail to the full executor when it is set.
//
// End-to-end acceptance: `zig build test-gql-conformance` (T11/T12/T14).
// These unit tests pin the classifier itself.

const std = @import("std");
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

test "GAP-0892: SESSION SET before count(*) is an effectful preamble" {
    const prog, var arena = try parseProgram("SESSION SET PROPERTY GRAPH \"G1\";\nMATCH (n) RETURN count(*) AS c");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try std.testing.expect(analysis.target != null);
    try std.testing.expect(analysis.has_effectful_preamble);
}

test "GAP-0892: bare count(*) query has no effectful preamble" {
    const prog, var arena = try parseProgram("MATCH (n) RETURN count(*) AS c");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try std.testing.expect(analysis.target != null);
    try std.testing.expect(!analysis.has_effectful_preamble);
}

test "GAP-0892: transaction control statements stay fast-path eligible" {
    const prog, var arena = try parseProgram("START TRANSACTION;\nMATCH (n) RETURN count(*) AS c;\nCOMMIT");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try std.testing.expect(analysis.target != null);
    try std.testing.expect(!analysis.has_effectful_preamble);
}

test "GAP-0892: trailing SESSION SET after the target is also flagged" {
    const prog, var arena = try parseProgram("MATCH (n) RETURN count(*) AS c;\nSESSION SET PROPERTY GRAPH \"G2\"");
    defer arena.deinit();
    const analysis = query_traits.analyzeProgram(&prog);
    try std.testing.expect(analysis.target != null);
    try std.testing.expect(analysis.has_effectful_preamble);
}
