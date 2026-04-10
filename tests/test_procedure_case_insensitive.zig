// Case-insensitive procedure dispatch regression tests.
//
// Per ISO/IEC 39075:2024 RQ-0022, GQL reserved keywords, function names, and
// stored procedure names must be recognized regardless of ASCII case. Before
// this fix, `procedure_registry.executeCallProcedure` compared the procedure
// name against canonical lowercase literals using `std.mem.eql`, so
// `CALL ALGO.DEGREE.STREAM()` raised `UnknownProcedure` while
// `CALL algo.degree.stream()` succeeded.
//
// These tests exercise two layers:
//
//   1. Unit tests for `extractNormalizedProcName`, the pure helper that pulls
//      the procedure name out of the AST and ASCII-lowercases it once so all
//      downstream dispatch modules can keep their existing exact-match
//      comparisons.
//
//   2. Unit tests for `geode.language_metadata.findProcedure` verifying the
//      metadata catalog used by LSP/semantic diagnostics resolves any-case
//      procedure names.
//
// CANARY: REQ=REQ-GQL-CASE-INSENSITIVE-002; FEATURE="CaseInsensitiveProcedures"; ASPECT=Dispatch; STATUS=TESTED; OWNER=execution; UPDATED=2026-04-10

const std = @import("std");
const geode = @import("geode");
const ast = geode.ast;
const execution = geode.execution;
const procedure_registry = execution.procedure_registry;
const language_metadata = geode.language_metadata;

// ---------------------------------------------------------------------------
// Helpers to construct minimal CallProcedure AST nodes
// ---------------------------------------------------------------------------

fn makeIdentCall(ident_expr: *ast.Expr) ast.CallProcedure {
    const args: []*ast.Expr = &.{};
    const call_expr = ast.Expr{ .Call = .{ .callee = ident_expr, .args = args } };
    return ast.CallProcedure{ .procedure = call_expr };
}

fn makeMemberCall(outer_member: *ast.Expr) ast.CallProcedure {
    const args: []*ast.Expr = &.{};
    const call_expr = ast.Expr{ .Call = .{ .callee = outer_member, .args = args } };
    return ast.CallProcedure{ .procedure = call_expr };
}

// ---------------------------------------------------------------------------
// extractNormalizedProcName — Ident callee (single identifier, e.g. alias)
// ---------------------------------------------------------------------------

test "extractNormalizedProcName: uppercase alias is lowercased" {
    const allocator = std.testing.allocator;

    var callee = ast.Expr{ .Ident = .{ .orig = "PAGERANK", .cnf = "PAGERANK" } };
    const call_proc = makeIdentCall(&callee);

    const normalized = try procedure_registry.extractNormalizedProcName(allocator, call_proc);
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("pagerank", normalized);
}

test "extractNormalizedProcName: mixed-case alias is lowercased" {
    const allocator = std.testing.allocator;

    var callee = ast.Expr{ .Ident = .{ .orig = "PageRank", .cnf = "PAGERANK" } };
    const call_proc = makeIdentCall(&callee);

    const normalized = try procedure_registry.extractNormalizedProcName(allocator, call_proc);
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("pagerank", normalized);
}

test "extractNormalizedProcName: already-lowercase alias is preserved" {
    const allocator = std.testing.allocator;

    var callee = ast.Expr{ .Ident = .{ .orig = "degree", .cnf = "DEGREE" } };
    const call_proc = makeIdentCall(&callee);

    const normalized = try procedure_registry.extractNormalizedProcName(allocator, call_proc);
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("degree", normalized);
}

// ---------------------------------------------------------------------------
// extractNormalizedProcName — Member callee (dotted names like algo.x.y)
// ---------------------------------------------------------------------------

test "extractNormalizedProcName: uppercase dotted path is lowercased" {
    const allocator = std.testing.allocator;

    // Build AST for `ALGO.DEGREE.STREAM`:
    //   Member{ target: Member{ target: Ident("ALGO"), field: "DEGREE" }, field: "STREAM" }
    var ident = ast.Expr{ .Ident = .{ .orig = "ALGO", .cnf = "ALGO" } };
    var middle = ast.Expr{ .Member = .{ .target = &ident, .field = "DEGREE" } };
    var outer = ast.Expr{ .Member = .{ .target = &middle, .field = "STREAM" } };
    const call_proc = makeMemberCall(&outer);

    const normalized = try procedure_registry.extractNormalizedProcName(allocator, call_proc);
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("algo.degree.stream", normalized);
}

test "extractNormalizedProcName: mixed-case dotted path is lowercased" {
    const allocator = std.testing.allocator;

    // `Algo.PageRank.Stream` — the form docs use for the pagerank procedure.
    var ident = ast.Expr{ .Ident = .{ .orig = "Algo", .cnf = "ALGO" } };
    var middle = ast.Expr{ .Member = .{ .target = &ident, .field = "PageRank" } };
    var outer = ast.Expr{ .Member = .{ .target = &middle, .field = "Stream" } };
    const call_proc = makeMemberCall(&outer);

    const normalized = try procedure_registry.extractNormalizedProcName(allocator, call_proc);
    defer allocator.free(normalized);

    // This matches the canonical form algo_dispatch.zig compares against.
    try std.testing.expectEqualStrings("algo.pagerank.stream", normalized);
}

test "extractNormalizedProcName: lowercase dotted path is preserved" {
    const allocator = std.testing.allocator;

    // Regression safety: the already-working lowercase form must still resolve.
    var ident = ast.Expr{ .Ident = .{ .orig = "algo", .cnf = "ALGO" } };
    var middle = ast.Expr{ .Member = .{ .target = &ident, .field = "pagerank" } };
    var outer = ast.Expr{ .Member = .{ .target = &middle, .field = "stream" } };
    const call_proc = makeMemberCall(&outer);

    const normalized = try procedure_registry.extractNormalizedProcName(allocator, call_proc);
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("algo.pagerank.stream", normalized);
}

// ---------------------------------------------------------------------------
// language_metadata.findProcedure — case-insensitive metadata lookup
// (GAP-A fix, covered here again as an integration-level guarantee)
// ---------------------------------------------------------------------------

test "findProcedure: uppercase dotted name resolves" {
    const info = language_metadata.findProcedure("ALGO.PAGERANK.STREAM");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("algo.pagerank.stream", info.?.name);
}

test "findProcedure: mixed-case dotted name resolves" {
    const info = language_metadata.findProcedure("Algo.PageRank.Stream");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("algo.pagerank.stream", info.?.name);
}

test "findProcedure: uppercase alias resolves" {
    const info = language_metadata.findProcedure("PAGERANK");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("algo.pagerank.stream", info.?.name);
}

test "findProcedure: unknown name still returns null" {
    const info = language_metadata.findProcedure("NOT.A.PROCEDURE");
    try std.testing.expect(info == null);
}

test "findFunction: uppercase name resolves" {
    const info = language_metadata.findFunction("COUNT");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("count", info.?.name);
}

test "findFunction: mixed-case name resolves" {
    const info = language_metadata.findFunction("CoUnT");
    try std.testing.expect(info != null);
}
