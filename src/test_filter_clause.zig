const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");

// CANARY: REQ=REQ-GQL-FILTER-001; FEATURE="FilterClause"; ASPECT=BasicFiltering; STATUS=TESTED; TEST=TestFilterBasic; OWNER=engine; UPDATED=2025-10-08
test "FILTER clause - basic filtering" {
    const allocator = testing.allocator;
    const query = "MATCH (n) FILTER WHERE n.age > 25 RETURN n";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.filter_clause != null);
    try testing.expect(q.filter_clause.? == .Binary);
    try testing.expect(q.filter_clause.?.Binary.op == .Gt);
}

// CANARY: REQ=REQ-GQL-FILTER-002; FEATURE="FilterClause"; ASPECT=WithoutWhereKeyword; STATUS=TESTED; TEST=TestFilterWithoutWhere; OWNER=engine; UPDATED=2025-10-08
test "FILTER clause - without WHERE keyword" {
    const allocator = testing.allocator;
    const query = "MATCH (n) FILTER n.city = 'NYC' RETURN n";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.filter_clause != null);
    try testing.expect(q.filter_clause.? == .Binary);
    try testing.expect(q.filter_clause.?.Binary.op == .Eq);
}

// CANARY: REQ=REQ-GQL-FILTER-003; FEATURE="FilterClause"; ASPECT=CombinedWithWhere; STATUS=TESTED; TEST=TestFilterWithWhere; OWNER=engine; UPDATED=2025-10-08
test "FILTER clause - combined with WHERE clause" {
    const allocator = testing.allocator;
    const query = "MATCH (n) WHERE n.active = true FILTER WHERE n.age > 18 RETURN n";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.where_clause != null);
    try testing.expect(q.filter_clause != null);

    // Both clauses should be parsed correctly
    try testing.expect(q.where_clause.? == .Binary);
    try testing.expect(q.filter_clause.? == .Binary);
}

// CANARY: REQ=REQ-GQL-FILTER-004; FEATURE="FilterClause"; ASPECT=ComplexExpression; STATUS=TESTED; TEST=TestFilterComplex; OWNER=engine; UPDATED=2025-10-08
test "FILTER clause - complex expression" {
    const allocator = testing.allocator;
    const query = "MATCH (n) FILTER WHERE n.score > 80 AND n.verified = true RETURN n";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.filter_clause != null);
    try testing.expect(q.filter_clause.? == .Binary);
    try testing.expect(q.filter_clause.?.Binary.op == .And);
}

// CANARY: REQ=REQ-GQL-FILTER-005; FEATURE="FilterClause"; ASPECT=RelationshipPattern; STATUS=TESTED; TEST=TestFilterRelationship; OWNER=engine; UPDATED=2025-10-08
test "FILTER clause - with relationship pattern" {
    const allocator = testing.allocator;
    const query = "MATCH (a)-[r]->(b) FILTER WHERE r.weight > 0.5 RETURN a, b";

    var result = try lib.parse(allocator, query, .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
    const stmt = result.program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.filter_clause != null);
    try testing.expect(q.filter_clause.? == .Binary);
}
