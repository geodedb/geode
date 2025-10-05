const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=FrontierAndResultGuardTrips; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_MatchGuardTrips; OWNER=engine; UPDATED=2025-09-24

fn buildSmallGraph(ally: std.mem.Allocator, fanout: usize) geode.graph_common.GraphStorage {
    var g = geode.graph_common.GraphStorage.init(ally);
    // Create star graph: 1 connected to 2..fanout+1
    const center: u64 = 1;
    try g.addNode(ally, center, &.{});
    var i: usize = 0;
    while (i < fanout) : (i += 1) {
        const nid: u64 = @intCast(i + 2);
        try g.addNode(ally, nid, &.{});
        _ = try g.addEdge(ally, center, nid, "KNOWS");
    }
    return g;
}

// Force frontier guard by setting max_frontier extremely low
test "TestCANARY_REQ_GQL_017_MatchGuardTrips frontier" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var g = buildSmallGraph(ally, 5);
    defer g.deinit(ally);

    const query_txt = "MATCH (a)-[:KNOWS*1..2]->(b) RETURN a, b";
    var parsed = try geode.parseGql(query_txt, ally);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const opts = geode.graph_common.MatchOptions{ .max_frontier = 2, .max_results = 100, .max_hops_limit = 4 };
    const res = geode.graph_common.executeMatch(ally, &g, query.match, query.where_clause, opts, &diag) catch {};
    // We expect a guard trip diagnostic
    try std.testing.expect(diag == .ExecutionGuardTrip);
    // Even if partial results produced, ensure not exceeding frontier bound massively
    if (res.len > 0) {
        try std.testing.expect(res.len <= 100);
    }
}

// Force result guard by setting max_results extremely low
test "TestCANARY_REQ_GQL_017_MatchGuardTrips results" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var g = buildSmallGraph(ally, 20);
    defer g.deinit(ally);

    const query_txt = "MATCH (a)-[:KNOWS]->(b) RETURN a, b"; // single hop yields many edges
    var parsed = try geode.parseGql(query_txt, ally);
    defer parsed.deinit();
    const query = parsed.program.statements[0].Query;
    var diag: geode.diagnostics.Code = .None;
    const opts = geode.graph_common.MatchOptions{ .max_frontier = 1_000, .max_results = 3, .max_hops_limit = 4 };
    const res = geode.graph_common.executeMatch(ally, &g, query.match, query.where_clause, opts, &diag) catch {};
    try std.testing.expect(diag == .ExecutionGuardTrip);
    try std.testing.expect(res.len <= 3);
}
