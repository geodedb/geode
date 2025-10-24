const std = @import("std");
const geode = @import("geode");

test "WITH clause execution - simple projection" {
    const allocator = std.testing.allocator;

    // Test simple WITH clause that projects a subset of variables
    // This tests the basic functionality without needing the full graph infrastructure

    // Parse a simple query with WITH
    const query_text = "MATCH (n) WITH n RETURN n";
    var res = try geode.parseGql(query_text, allocator);
    defer res.deinit();

    const query = res.program.statements[0].Query;
    try std.testing.expect(query.with_clause != null);
    try std.testing.expectEqual(@as(usize, 1), query.with_clause.?.items.len);
    try std.testing.expectEqualStrings("n", query.with_clause.?.items[0].expr.Ident);
}

test "WITH clause parsing - with aggregation" {
    const allocator = std.testing.allocator;

    // Test WITH clause with aggregation function
    const query_text = "MATCH (n) WITH n, count(*) AS c RETURN n, c";
    var res = try geode.parseGql(query_text, allocator);
    defer res.deinit();

    const query = res.program.statements[0].Query;
    try std.testing.expect(query.with_clause != null);
    try std.testing.expectEqual(@as(usize, 2), query.with_clause.?.items.len);

    // First item should be n
    try std.testing.expectEqualStrings("n", query.with_clause.?.items[0].expr.Ident);

    // Second item should be count(*) with alias c
    const count_item = query.with_clause.?.items[1];
    try std.testing.expect(count_item.alias != null);
    try std.testing.expectEqualStrings("c", count_item.alias.?);
    try std.testing.expect(count_item.expr == .Call);
}

test "WITH clause parsing - with WHERE" {
    const allocator = std.testing.allocator;

    // Test WITH clause followed by WHERE
    const query_text = "MATCH (n) WITH n WHERE n.age > 18 RETURN n";
    var res = try geode.parseGql(query_text, allocator);
    defer res.deinit();

    const query = res.program.statements[0].Query;
    try std.testing.expect(query.with_clause != null);
    try std.testing.expect(query.where_clause != null);

    // WHERE clause should be merged into the query
    try std.testing.expect(query.where_clause.? == .Binary);
}
