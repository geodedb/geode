const std = @import("std");
const gql = @import("gql.zig");
const parser_mod = @import("gql/parser.zig");
const lexer_mod = @import("gql/lexer.zig");
const ast = @import("gql/ast.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="Aggregation COUNT DISTINCT"; ASPECT=CountDistinctParser; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_CountDistinctParser; OWNER=engine; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_012_CountDistinctParser" {
    const source = "RETURN COUNT(DISTINCT x) GROUP BY x";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var lx = lexer_mod.Lexer.init(source);
    var p = parser_mod.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const prog = try p.parseProgram();
    try std.testing.expect(prog.statements.len == 1);
    const st = prog.statements[0];
    try std.testing.expect(st == .Query);
    const q = st.Query;
    try std.testing.expect(q.group_by != null);
    try std.testing.expect(q.ret.items.len == 1);
    const expr = q.ret.items[0].expr;
    try std.testing.expect(expr == .Call);
    const call = expr.Call;
    try std.testing.expect(call.callee.* == .Ident);
    // Should have been rewritten to countDistinct
    try std.testing.expect(std.ascii.eqlIgnoreCase(call.callee.Ident, "countDistinct"));
    try std.testing.expect(call.args.len == 1);
    try std.testing.expect(call.args[0].*.Ident.len == 1);
}
