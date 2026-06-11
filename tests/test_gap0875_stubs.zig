//! GAP-0875: residual local stubs batch — regression tests.
//!
//! (a) ConstraintManager unique-constraint validation consults an attached
//!     property index (previously a silent no-op placeholder).
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
const cm = geode.constraint_manager;
const ast = geode.gql.ast;
const Lexer = geode.gql.lexer.Lexer;
const Parser = geode.gql.parser.Parser;
const print_mod = geode.printer;
const mmio = geode.memory_mapped_io;

// ---------------------------------------------------------------------------
// (a) Unique constraint consults the attached property index
// ---------------------------------------------------------------------------

/// Minimal in-memory unique-property index for the test: maps
/// "label\x00property\x00string-value" -> existing entity id.
const TestUniqueIndex = struct {
    map: std.StringHashMap(u64),

    fn lookup(ctx: ?*anyopaque, label: []const u8, property: []const u8, value: cm.Value) ?u64 {
        const self: *TestUniqueIndex = @ptrCast(@alignCast(ctx.?));
        if (value != .string) return null;
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}\x00{s}", .{ label, property, value.string }) catch return null;
        return self.map.get(key);
    }
};

test "GAP-0875a: duplicate value under unique constraint with index attached is a violation" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mgr = cm.ConstraintManager.init(allocator);
    defer mgr.deinit();

    var props_list = [_][]const u8{"email"};
    try mgr.createUniqueConstraint("uq_user_email", .node, "User", props_list[0..]);

    var idx = TestUniqueIndex{ .map = std.StringHashMap(u64).init(allocator) };
    defer {
        var it = idx.map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        idx.map.deinit();
    }
    // Entity 1 already holds email=alice@example.com in the index.
    try idx.map.put(try allocator.dupe(u8, "User\x00email\x00alice@example.com"), 1);

    mgr.attachUniqueIndex(.{ .ctx = &idx, .lookup = TestUniqueIndex.lookup });

    // Inserting the SAME value as a DIFFERENT entity violates the constraint.
    var node_props = std.StringHashMap(cm.Value).init(allocator);
    defer node_props.deinit();
    try node_props.put("email", .{ .string = "alice@example.com" });

    const errs = try mgr.validateNode(2, "User", node_props);
    defer {
        for (errs) |e| allocator.free(e.message);
        allocator.free(errs);
    }
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqual(cm.ConstraintType.unique, errs[0].constraint_type);
    try std.testing.expectEqual(@as(u64, 2), errs[0].entity_id);
    try std.testing.expect(errs[0].property != null);
    try std.testing.expectEqualStrings("email", errs[0].property.?);

    // The owning entity re-validating its own value is NOT a violation.
    const errs_self = try mgr.validateNode(1, "User", node_props);
    defer allocator.free(errs_self);
    try std.testing.expectEqual(@as(usize, 0), errs_self.len);

    // A distinct value is NOT a violation.
    var node_props2 = std.StringHashMap(cm.Value).init(allocator);
    defer node_props2.deinit();
    try node_props2.put("email", .{ .string = "bob@example.com" });
    const errs2 = try mgr.validateNode(3, "User", node_props2);
    defer allocator.free(errs2);
    try std.testing.expectEqual(@as(usize, 0), errs2.len);
}

test "GAP-0875a: without an attached index unique validation reports nothing (documented residual)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mgr = cm.ConstraintManager.init(allocator);
    defer mgr.deinit();

    var props_list = [_][]const u8{"email"};
    try mgr.createUniqueConstraint("uq_user_email", .node, "User", props_list[0..]);

    var node_props = std.StringHashMap(cm.Value).init(allocator);
    defer node_props.deinit();
    try node_props.put("email", .{ .string = "alice@example.com" });

    const errs = try mgr.validateNode(2, "User", node_props);
    defer allocator.free(errs);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

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
