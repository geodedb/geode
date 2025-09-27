const std = @import("std");
const testing = std.testing;
const test_harness = @import("test_harness");

test "T1: SKIP recognized" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS x UNION ALL RETURN 2 AS x UNION ALL RETURN 3 AS x SKIP 1 LIMIT 1";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"x\"],\"rows\":[[2]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T2: LIMIT without ORDER BY allowed" {
    var allocator = testing.allocator;
    const query = "RETURN 3 AS x UNION ALL RETURN 1 AS x UNION ALL RETURN 2 AS x LIMIT 2";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"x\"],\"rows\":[[1],[2]],\"flagger_findings\":[\"U:OrderTiebreak=LexJSON\"]}";
    try testing.expectEqualStrings(expected, result);
}

test "T3: ORDER BY expression allowed" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS a, 2 AS b UNION ALL RETURN 2 AS a, 3 AS b ORDER BY a + b DESC";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"a\",\"b\"],\"rows\":[[2,3],[1,2]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T4: Per-key NULLS policy - LAST" {
    var allocator = testing.allocator;
    const query = "RETURN NULL AS x UNION ALL RETURN 1 AS x ORDER BY x NULLS LAST";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"x\"],\"rows\":[[1],[null]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T5: Per-key NULLS policy - mixed" {
    var allocator = testing.allocator;
    const query = "RETURN NULL AS a, 1 AS b UNION ALL RETURN 1 AS a, NULL AS b ORDER BY a NULLS FIRST, b NULLS LAST";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"a\",\"b\"],\"rows\":[[null,1],[1,null]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T6: Quoted identifier as alias" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS \"order\"";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"order\"],\"rows\":[[1]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T7: UNKNOWN keyword" {
    var allocator = testing.allocator;
    const query = "RETURN NULL IS UNKNOWN AS u, 5 IS NOT UNKNOWN AS v";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"u\",\"v\"],\"rows\":[[true,false]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T8: // comment accepted + flagged" {
    var allocator = testing.allocator;
    const query = 
        \\// head
        \\RETURN 1 AS x // tail
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"x\"],\"rows\":[[1]],\"flagger_findings\":[\"GB03:DoubleSolidusComment\"]}";
    try testing.expectEqualStrings(expected, result);
}

test "T9: ORDER BY ordinal allowed + flagged" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS a, 2 AS b ORDER BY 2";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"a\",\"b\"],\"rows\":[[1,2]],\"flagger_findings\":[\"E:OrdinalSortKey\"]}";
    try testing.expectEqualStrings(expected, result);
}

test "T10: -- disabled (clear diagnostic)" {
    var allocator = testing.allocator;
    const query = "RETURN 1 -- nope";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"42000\",\"message\":\"syntax error: double-hyphen comments disabled (GB02)\",\"additional_statuses\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T11: Session graph switch applies" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH "G1";
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"c\"],\"rows\":[[3]],\"flagger_findings\":[\"I:GraphCatalog=memory\"]}";
    try testing.expectEqualStrings(expected, result);
}

test "T12: Switch to another graph" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G2;
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"c\"],\"rows\":[[2]],\"flagger_findings\":[\"I:GraphCatalog=memory\"]}";
    try testing.expectEqualStrings(expected, result);
}

test "T13: Non-existent graph auto-create (empty)" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH "NewG";
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"c\"],\"rows\":[[0]],\"flagger_findings\":[\"I:GraphCatalog=memory\"]}";
    try testing.expectEqualStrings(expected, result);
}

test "T14: COUNT(*) over matches" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"c\"],\"rows\":[[3]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T15: GROUP BY property with HAVING" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN n.label AS L, count(*) AS c GROUP BY n.label HAVING c >= 2 ORDER BY L
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"L\",\"c\"],\"rows\":[[\"A\",2]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T16: SUM/AVG with NULLs skipped" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN sum(n.v) AS s, avg(n.v) AS a
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"s\",\"a\"],\"rows\":[[3,1.5]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T17: COUNT(expr) vs COUNT(*)" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN count(n.v) AS cnv, count(*) AS cstar
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"cnv\",\"cstar\"],\"rows\":[[2,3]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T18: COUNT(DISTINCT …)" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G2;
        \\MATCH (n) RETURN count(DISTINCT n.v) AS d
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"00000\",\"columns\":[\"d\"],\"rows\":[[1]],\"flagger_findings\":[]}";
    try testing.expectEqualStrings(expected, result);
}

test "T19: GROUP BY legality (error)" {
    var allocator = testing.allocator;
    const query = 
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN n.label, sum(n.v)
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);
    
    const expected = "{\"status_class\":\"42000\",\"message\":\"grouping error: non-aggregated expression not in GROUP BY\",\"additional_statuses\":[]}";
    try testing.expectEqualStrings(expected, result);
}

// Cleanup test catalog at the end
test "ZZ_cleanup" {
    test_harness.cleanupTestCatalog();
}