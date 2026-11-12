//! GAP-0875: residual local stubs batch — regression tests.
//!
//! (a) Removed (SONNY-6354): it covered `src/schema/constraint_manager.zig`,
//!     a second constraint implementation no write path used; constraints
//!     are enforced by `execution/unique_constraints.zig` and the catalog.
//! (b) GQL printer renders IN / NOT IN subqueries in re-parseable compact
//!     form (previously the opaque literal "(subquery)"), and the temporal
//!     walker descends into IN-subqueries so temporal literals inside them
//!     are collected for JSON temporal output.
//! (c) benchmarkMemoryMappedIO measures writes independently (previously the
//!     write numbers were copied from the read totals).
//!
//! MCP cancellation propagation (tools.callTool) is covered separately in
//! tests/test_gap0875_stubs_mcp.zig (needs the mcp/json/geode module set).
//
// CANARY: REQ=GAP-0875; FEATURE="ResidualStubsBatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0875_stubs.zig; OWNER=core; UPDATED=2026-06-11

const std = @import("std");
const geode = @import("geode");
const ast = geode.gql.ast;
const Lexer = geode.gql.lexer.Lexer;
const Parser = geode.gql.parser.Parser;
const print_mod = geode.printer;
const mmio = geode.memory_mapped_io;

// ---------------------------------------------------------------------------
// (b) Printer renders IN / NOT IN subqueries re-parseably
// ---------------------------------------------------------------------------

fn parseProg(arena: *std.heap.ArenaAllocator, src_text: []const u8) !ast.Program {
    var lexer = Lexer{ .src = src_text };
    var p = Parser{ .lx = &lexer, .arena = arena, .cur = lexer.next() };
    return p.parseProgram();
}

fn whereExprOf(prog: ast.Program) ast.Expr {
    return prog.statements[0].Query.where_clause.?;
}

test "GAP-0875b: IN (subquery) parse -> print -> reparse round-trip preserves the expression" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src1 = "MATCH (n:Person) WHERE n.id IN (MATCH (m:User) WHERE m.score > 1 RETURN m.id) RETURN n";
    var arena1 = std.heap.ArenaAllocator.init(allocator);
    defer arena1.deinit();
    const prog1 = try parseProg(&arena1, src1);
    const printed1 = try print_mod.stringifyExprAlloc(allocator, whereExprOf(prog1), .{});
    defer allocator.free(printed1);

    // The opaque placeholder must be gone and the subquery body present.
    try std.testing.expect(std.mem.indexOf(u8, printed1, "(subquery)") == null);
    try std.testing.expect(std.mem.indexOf(u8, printed1, "m.id") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed1, "m.score") != null);

    // Reparse the printed expression and verify the fixed point.
    const src2 = try std.fmt.allocPrint(allocator, "MATCH (n:Person) WHERE {s} RETURN n", .{printed1});
    defer allocator.free(src2);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const prog2 = try parseProg(&arena2, src2);
    const printed2 = try print_mod.stringifyExprAlloc(allocator, whereExprOf(prog2), .{});
    defer allocator.free(printed2);
    try std.testing.expectEqualStrings(printed1, printed2);
}

test "GAP-0875b: NOT IN (subquery) parse -> print -> reparse round-trip preserves the expression" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src1 = "MATCH (n:Person) WHERE n.id NOT IN (MATCH (m:User) RETURN m.id) RETURN n";
    var arena1 = std.heap.ArenaAllocator.init(allocator);
    defer arena1.deinit();
    const prog1 = try parseProg(&arena1, src1);
    const printed1 = try print_mod.stringifyExprAlloc(allocator, whereExprOf(prog1), .{});
    defer allocator.free(printed1);

    try std.testing.expect(std.mem.indexOf(u8, printed1, "(subquery)") == null);
    try std.testing.expect(std.mem.indexOf(u8, printed1, "NOT IN") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed1, "m.id") != null);

    const src2 = try std.fmt.allocPrint(allocator, "MATCH (n:Person) WHERE {s} RETURN n", .{printed1});
    defer allocator.free(src2);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const prog2 = try parseProg(&arena2, src2);
    const printed2 = try print_mod.stringifyExprAlloc(allocator, whereExprOf(prog2), .{});
    defer allocator.free(printed2);
    try std.testing.expectEqualStrings(printed1, printed2);
}

test "GAP-0875b: IN [list] print is a fixed point (control)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src1 = "MATCH (n) WHERE n.id IN [1, 2, 3] RETURN n";
    var arena1 = std.heap.ArenaAllocator.init(allocator);
    defer arena1.deinit();
    const prog1 = try parseProg(&arena1, src1);
    const printed1 = try print_mod.stringifyExprAlloc(allocator, whereExprOf(prog1), .{});
    defer allocator.free(printed1);

    const src2 = try std.fmt.allocPrint(allocator, "MATCH (n) WHERE {s} RETURN n", .{printed1});
    defer allocator.free(src2);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const prog2 = try parseProg(&arena2, src2);
    const printed2 = try print_mod.stringifyExprAlloc(allocator, whereExprOf(prog2), .{});
    defer allocator.free(printed2);
    try std.testing.expectEqualStrings(printed1, printed2);
}

test "GAP-0875b: temporal walker collects temporals inside IN-subqueries" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src = "MATCH (n) WHERE n.id IN (MATCH (m) WHERE m.d = DATE \"2024-01-02\" RETURN m.id) RETURN n";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const prog = try parseProg(&arena, src);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try print_mod.printProgramJsonWith(allocator, &aw.writer, prog, .{ .verbose_temporals = true });
    const json_out = aw.writer.buffered();
    // The Date literal lives only inside the IN-subquery; before GAP-0875 the
    // walker skipped subqueries and this temporal never reached the output.
    try std.testing.expect(std.mem.indexOf(u8, json_out, "2024-01-02") != null);
}

// ---------------------------------------------------------------------------
// (c) Memory-mapped write benchmark measures writes
// ---------------------------------------------------------------------------

test "GAP-0875: benchmarkMemoryMappedIO write numbers are measured, not copied from reads" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const res = try mmio.benchmarkMemoryMappedIO(allocator, 64 * 1024, 3);
    try std.testing.expect(res.mmap_read_ns > 0);
    try std.testing.expect(res.regular_read_ns > 0);
    try std.testing.expect(res.mmap_write_ns > 0);
    try std.testing.expect(res.regular_write_ns > 0);
    // The pre-fix placeholder copied BOTH write totals verbatim from the read
    // totals; independently-measured timings cannot both coincide exactly.
    try std.testing.expect(!(res.mmap_write_ns == res.mmap_read_ns and
        res.regular_write_ns == res.regular_read_ns));
}
