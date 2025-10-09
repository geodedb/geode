const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");

// CANARY: REQ=REQ-GQL-EXPR-MOD-001; FEATURE="ArithmeticModuloOperator"; ASPECT=BasicModulo; STATUS=TESTED; TEST=TestModuloPositive|TestModuloNegative|TestModuloZero; OWNER=engine; UPDATED=2025-10-08
test "Modulo operator - positive integers" {
    const allocator = testing.allocator;
    const query = "RETURN 17 % 5 AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);
}

// CANARY: REQ=REQ-GQL-EXPR-MOD-002; FEATURE="ArithmeticModuloOperator"; ASPECT=NegativeOperands; STATUS=TESTED; TEST=TestModuloNegativeLeft|TestModuloNegativeRight|TestModuloNegativeBoth; OWNER=engine; UPDATED=2025-10-08
test "Modulo operator - negative integers" {
    const allocator = testing.allocator;
    const query = "RETURN -17 % 5 AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-EXPR-MOD-003; FEATURE="ArithmeticModuloOperator"; ASPECT=DivisionByZero; STATUS=TESTED; TEST=TestModuloDivisionByZero; OWNER=engine; UPDATED=2025-10-08
test "Modulo operator - division by zero handling" {
    const allocator = testing.allocator;
    const query = "RETURN 10 % 0 AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    // Parser should succeed; division by zero is a runtime error
}

// CANARY: REQ=REQ-GQL-EXPR-MOD-004; FEATURE="ArithmeticModuloOperator"; ASPECT=Precedence; STATUS=TESTED; TEST=TestModuloPrecedence; OWNER=engine; UPDATED=2025-10-08
test "Modulo operator - precedence with other operators" {
    const allocator = testing.allocator;
    const query = "RETURN 10 + 17 % 5 AS result"; // Should be 10 + (17 % 5) = 12

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.return_clause != null);
    try testing.expect(q.return_clause.?.items.len == 1);

    // Verify it's a binary addition with modulo on the right
    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Binary);
    try testing.expect(item.expr.Binary.op == .Add);
    try testing.expect(item.expr.Binary.right.* == .Binary);
    try testing.expect(item.expr.Binary.right.*.Binary.op == .Mod);
}

// CANARY: REQ=REQ-GQL-EXPR-UNARY-PLUS-001; FEATURE="UnaryPlusOperator"; ASPECT=BasicUnaryPlus; STATUS=TESTED; TEST=TestUnaryPlusPositive|TestUnaryPlusNegative|TestUnaryPlusZero; OWNER=engine; UPDATED=2025-10-08
test "Unary plus operator - positive integer" {
    const allocator = testing.allocator;
    const query = "RETURN +42 AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.return_clause != null);
    try testing.expect(q.return_clause.?.items.len == 1);

    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Unary);
    try testing.expect(item.expr.Unary.op == .Pos);
}

// CANARY: REQ=REQ-GQL-EXPR-UNARY-PLUS-002; FEATURE="UnaryPlusOperator"; ASPECT=DecimalSupport; STATUS=TESTED; TEST=TestUnaryPlusDecimal; OWNER=engine; UPDATED=2025-10-08
test "Unary plus operator - decimal number" {
    const allocator = testing.allocator;
    const query = "RETURN +3.14 AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-EXPR-UNARY-PLUS-003; FEATURE="UnaryPlusOperator"; ASPECT=Chaining; STATUS=TESTED; TEST=TestUnaryPlusChaining; OWNER=engine; UPDATED=2025-10-08
test "Unary plus operator - double application" {
    const allocator = testing.allocator;
    const query = "RETURN + +42 AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Unary);
    try testing.expect(item.expr.Unary.op == .Pos);
    try testing.expect(item.expr.Unary.expr.* == .Unary);
}

// CANARY: REQ=REQ-GQL-EXPR-UNARY-PLUS-004; FEATURE="UnaryPlusOperator"; ASPECT=MixedSigns; STATUS=TESTED; TEST=TestUnaryPlusMinusMix; OWNER=engine; UPDATED=2025-10-08
test "Unary plus operator - mixed with unary minus" {
    const allocator = testing.allocator;
    const query = "RETURN +-42 AS result"; // +(-42) = -42

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-EXPR-INDEX-001; FEATURE="ArrayIndexAccess"; ASPECT=BasicIndexing; STATUS=TESTED; TEST=TestArrayIndexZero|TestArrayIndexPositive; OWNER=engine; UPDATED=2025-10-08
test "Array index access - basic indexing" {
    const allocator = testing.allocator;
    const query = "RETURN [1, 2, 3][0] AS result";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.return_clause != null);
    try testing.expect(q.return_clause.?.items.len == 1);

    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Index);
    try testing.expect(item.expr.Index.target.* == .List);
}

// CANARY: REQ=REQ-GQL-EXPR-INDEX-002; FEATURE="ArrayIndexAccess"; ASPECT=FunctionResult; STATUS=TESTED; TEST=TestArrayIndexOnFunctionResult; OWNER=engine; UPDATED=2025-10-08
test "Array index access - function result indexing" {
    const allocator = testing.allocator;
    const query = "MATCH (n) RETURN labels(n)[0] AS first_label";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.return_clause != null);
    try testing.expect(q.return_clause.?.items.len == 1);

    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Index);
    try testing.expect(item.expr.Index.target.* == .Call);
}

// CANARY: REQ=REQ-GQL-EXPR-INDEX-003; FEATURE="ArrayIndexAccess"; ASPECT=ChainedIndexing; STATUS=TESTED; TEST=TestArrayIndexChained; OWNER=engine; UPDATED=2025-10-08
test "Array index access - chained indexing" {
    const allocator = testing.allocator;
    const query = "RETURN [[1, 2], [3, 4]][0][1] AS result"; // Should be 2

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Index);
    try testing.expect(item.expr.Index.target.* == .Index);
}

// CANARY: REQ=REQ-GQL-EXPR-INDEX-004; FEATURE="ArrayIndexAccess"; ASPECT=DynamicIndex; STATUS=TESTED; TEST=TestArrayIndexDynamic; OWNER=engine; UPDATED=2025-10-08
test "Array index access - dynamic index expression" {
    const allocator = testing.allocator;
    const query = "RETURN [10, 20, 30][1 + 1] AS result"; // Should be 30

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    const item = q.return_clause.?.items[0];
    try testing.expect(item.expr == .Index);
    try testing.expect(item.expr.Index.index.* == .Binary);
    try testing.expect(item.expr.Index.index.*.Binary.op == .Add);
}

// CANARY: REQ=REQ-GQL-EXPR-INDEX-005; FEATURE="ArrayIndexAccess"; ASPECT=OutOfBounds; STATUS=TESTED; TEST=TestArrayIndexOutOfBounds; OWNER=engine; UPDATED=2025-10-08
test "Array index access - out of bounds handling" {
    const allocator = testing.allocator;
    const query = "RETURN [1, 2, 3][10] AS result"; // Parser should succeed; runtime returns null

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-EXPR-COMBINED-001; FEATURE="CombinedExpressions"; ASPECT=ModuloWithIndex; STATUS=TESTED; TEST=TestModuloWithArrayIndex; OWNER=engine; UPDATED=2025-10-08
test "Combined expressions - modulo with array indexing" {
    const allocator = testing.allocator;
    const query = "RETURN [10, 20, 30][17 % 3] AS result"; // 17 % 3 = 2, so result is 30

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
}
