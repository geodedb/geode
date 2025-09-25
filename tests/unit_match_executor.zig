const std = @import("std");
const geode = @import("geode");
const graph_exec = @import("server/graph/exec.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="MATCHExecutorBasic"; ASPECT=Unit; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_MatchSingleHop; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_MatchSingleHop" {
    const ally = std.testing.allocator;
    // Build tiny graph: 1-[:KNOWS]->2, 2-[:KNOWS]->3
    var g = graph_exec.GraphStorage.init(ally);
    defer g.deinit();
    try g.addNode(ally, 1, &.{"Person"});
    try g.setNodeProperty(1, "age", .{ .Int = 30 });
    try g.addNode(ally, 2, &.{"Person"});
    try g.setNodeProperty(2, "age", .{ .Int = 30 });
    try g.addNode(ally, 3, &.{"Person"});
    try g.setNodeProperty(3, "age", .{ .Int = 40 });
    _ = try g.addEdge(ally, 1, 2, "KNOWS");
    _ = try g.addEdge(ally, 2, 3, "KNOWS");

    const qtxt = "MATCH (a:Person {age:30})-[:KNOWS]->(b:Person) RETURN a, b";
    var parsed = try geode.parseGql(qtxt, ally);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const bindings = try graph_exec.executeMatch(ally, &g, query.match, query.where_clause, null, &diag);
    defer {
        for (bindings) |*b| b.deinit();
        ally.free(bindings);
    }
    try std.testing.expect(diag == .None or diag == .ExecutionGuardTrip and bindings.len > 0);
    try std.testing.expect(bindings.len > 0);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=Unit; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_InvalidHopBounds; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_InvalidHopBounds" {
    const ally = std.testing.allocator;
    var g = graph_exec.GraphStorage.init(ally);
    defer g.deinit();
    try g.addNode(ally, 1, &.{"X"});
    const qtxt = "MATCH (a:X)-[*3..1]->(b) RETURN a, b"; // min>max triggers guard
    var parsed = try geode.parseGql(qtxt, ally);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const res = graph_exec.executeMatch(ally, &g, query.match, query.where_clause, null, &diag);
    try std.testing.expectError(error.InvalidHopBounds, res);
    try std.testing.expect(diag == .ExecutionGuardTrip);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchEmptyGraph"; ASPECT=Unit; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_EmptyGraph; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_EmptyGraph" {
    const ally = std.testing.allocator;
    var g = graph_exec.GraphStorage.init(ally);
    defer g.deinit();
    const qtxt = "MATCH (a)-[:KNOWS]->(b) RETURN a, b";
    var parsed = try geode.parseGql(qtxt, ally);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const bindings = try graph_exec.executeMatch(ally, &g, query.match, query.where_clause, null, &diag);
    defer {
        for (bindings) |*b| b.deinit();
        ally.free(bindings);
    }
    try std.testing.expectEqual(@as(usize, 0), bindings.len);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="PathExpandBounded"; ASPECT=Unit; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_BoundedVarLen; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_BoundedVarLen" {
    const ally = std.testing.allocator;
    var g = graph_exec.GraphStorage.init(ally);
    defer g.deinit();
    try g.addNode(ally, 1, &.{"Person"});
    try g.addNode(ally, 2, &.{"Person"});
    try g.addNode(ally, 3, &.{"Person"});
    _ = try g.addEdge(ally, 1, 2, "KNOWS");
    _ = try g.addEdge(ally, 2, 3, "KNOWS");
    const qtxt = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a, b";
    var parsed = try geode.parseGql(qtxt, ally);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const bindings = try graph_exec.executeMatch(ally, &g, query.match, query.where_clause, null, &diag);
    defer {
        for (bindings) |*b| b.deinit();
        ally.free(bindings);
    }
    try std.testing.expect(bindings.len >= 2);
}
