const std = @import("std");
const geode = @import("geode");
const graph_exec = @import("server/graph/exec.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="MATCHExecutorBasic"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_MatchSingleHop; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_MatchSingleHop" {
    const allocator = std.testing.allocator;
    // Build tiny graph: 1-[:KNOWS]->2, 2-[:KNOWS]->3
    var g = graph_exec.GraphStore.init(allocator);
    defer g.deinit();
    var person_labels = [_][]const u8{"Person"};
    const n1 = try g.createNode(&person_labels);
    try g.setNodeProperty(n1, "age", .{ .Int = 30 });
    const n2 = try g.createNode(&person_labels);
    try g.setNodeProperty(n2, "age", .{ .Int = 30 });
    const n3 = try g.createNode(&person_labels);
    try g.setNodeProperty(n3, "age", .{ .Int = 40 });
    _ = try g.createEdge(n1, n2, "KNOWS");
    _ = try g.createEdge(n2, n3, "KNOWS");

    const qtxt = "MATCH (a:Person {age:30})-[:KNOWS]->(b:Person) RETURN a, b";
    var parsed = try geode.parseGql(qtxt, allocator);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const bindings = try graph_exec.executeMatch(allocator, &g, query.match, query.where_clause, null, &diag);
    defer {
        for (bindings) |*b| b.deinit();
        allocator.free(bindings);
    }
    try std.testing.expect(diag == .None or diag == .ExecutionGuardTrip and bindings.len > 0);
    try std.testing.expect(bindings.len > 0);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_InvalidHopBounds; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_InvalidHopBounds" {
    const allocator = std.testing.allocator;
    var g = graph_exec.GraphStore.init(allocator);
    defer g.deinit();
    var labels = [_][]const u8{"X"};
    _ = try g.createNode(&labels);
    const qtxt = "MATCH (a:X)-[*3..1]->(b) RETURN a, b"; // min>max triggers guard
    var parsed = try geode.parseGql(qtxt, allocator);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const res = graph_exec.executeMatch(allocator, &g, query.match, query.where_clause, null, &diag);
    try std.testing.expectError(error.InvalidHopBounds, res);
    try std.testing.expect(diag == .ExecutionGuardTrip);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchEmptyGraph"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_EmptyGraph; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_EmptyGraph" {
    const allocator = std.testing.allocator;
    var g = graph_exec.GraphStore.init(allocator);
    defer g.deinit();
    const qtxt = "MATCH (a)-[:KNOWS]->(b) RETURN a, b";
    var parsed = try geode.parseGql(qtxt, allocator);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const bindings = try graph_exec.executeMatch(allocator, &g, query.match, query.where_clause, null, &diag);
    defer {
        for (bindings) |*b| b.deinit();
        allocator.free(bindings);
    }
    try std.testing.expectEqual(@as(usize, 0), bindings.len);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="PathExpandBounded"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_BoundedVarLen; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_BoundedVarLen" {
    const allocator = std.testing.allocator;
    var g = graph_exec.GraphStore.init(allocator);
    defer g.deinit();
    var person_labels = [_][]const u8{"Person"};
    const a = try g.createNode(&person_labels);
    const b = try g.createNode(&person_labels);
    const c = try g.createNode(&person_labels);
    _ = try g.createEdge(a, b, "KNOWS");
    _ = try g.createEdge(b, c, "KNOWS");
    const qtxt = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a, b";
    var parsed = try geode.parseGql(qtxt, allocator);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const bindings = try graph_exec.executeMatch(allocator, &g, query.match, query.where_clause, null, &diag);
    defer {
        for (bindings) |*b| b.deinit();
        allocator.free(bindings);
    }
    try std.testing.expect(bindings.len >= 2);
}
