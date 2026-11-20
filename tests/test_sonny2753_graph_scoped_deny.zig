// SONNY-2753: a GPS policy scoped to one graph applies to that graph, and a
// deny scoped to graph g must not refuse what happens on another graph.
//
// `gps.decide` matched deny policies by `policyMatchesResource`, under which a
// policy scoped to g matched g and EVERY non-graph resource: the database,
// every procedure, every node and edge whatever graph it is in, metadata. So
// a DENY READ on g refused every read-only procedure on every graph, a DENY
// WRITE on g every procedure that writes, a deny on g a node of another graph,
// and a DENY DECRYPT_FIELD on g every decryption. (The handlers' graph write
// gate already asks for write on the graph the program changes,
// REQ-SEC-PER-GRAPH-GRANTS, so a plain write to another graph was no longer
// refused.) Allow policies already covered only their own graph.
//
// Now one rule covers allow and deny alike: a policy scoped to `*` covers
// everything; one scoped to g covers g and the nodes and edges in it, and
// nothing else. A request on no single graph (a procedure as such, the
// database) is covered by `*` policies. Where a request changes EVERY graph
// at once (a self-locking procedure CALL, `gps.writePermitted`; index,
// constraint and schema DDL, catalogued database-wide,
// `session_graph.maySchemaDatabase`), a deny on any graph refuses it, since
// it changes that graph too. A procedure CALL is also refused by a deny on
// the graph it runs on.
//
// Deny policies are installed through the real `PolicyCatalog`
// (`addPolicyStrict`, effect deny), as tests/test_sonny2744_gps_deny.zig
// does; `CREATE POLICY` always builds allow policies.
//
// CANARY: REQ=REQ-SONNY-2753-GRAPH-SCOPED-DENY; FEATURE="GPS Policy Evaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2753_graph_scoped_deny.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const wd = @import("sonny2753_gps_world.zig");

const gps = wd.gps;
const Kind = wd.Kind;
const World = wd.World;
const session_graph = geode.execution.session_graph;
const D = wd.graph_store.DEFAULT_GRAPH_NAME;

const read = [_]wd.policy_catalog.Action{.read};
const write = [_]wd.policy_catalog.Action{.write};
const schema_a = [_]wd.policy_catalog.Action{.schema};
const decrypt = [_]wd.policy_catalog.Action{.decrypt_field};

test "SONNY-2753: DENY WRITE on g1 refuses writes to g1 only; g2 and the default graph still take writes" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.policy("no_writes_g1", "g1", &write, .deny);
    // A fresh session for each request: a USE GRAPH that runs moves its
    // session.
    for ([_]struct { []const u8, wd.Role }{ .{ "rita", .ReadWrite }, .{ "ada", .Admin } }) |u| {
        try wd.expectDenied(ga, try w.session(u[0], u[1], null), "USE GRAPH g1; CREATE (:W {v: 1})");
        try wd.expectRuns(ga, try w.session(u[0], u[1], null), "USE GRAPH g2; CREATE (:W {v: 2})");
        try wd.expectRuns(ga, try w.session(u[0], u[1], null), "CREATE (:W {v: 3})");
        try wd.expectDenied(ga, try w.session(u[0], u[1], "g1"), "MATCH (n:C) SET n.v = 9");
    }
    try testing.expectEqual(@as(usize, 0), wd.countIn("g1", "W"));
    try testing.expectEqual(@as(usize, 2), wd.countIn("g2", "W"));
    try testing.expectEqual(@as(usize, 2), wd.countIn(D, "W"));
}

test "SONNY-2753: a graph-scoped DENY READ refuses read-only procedures on its graph only" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.policy("no_reads_g1", "g1", &read, .deny);
    try wd.expectDenied(ga, try w.session("rita", .ReadWrite, null), "USE GRAPH g1; CALL db.labels() YIELD label RETURN label");
    try wd.expectDenied(ga, try w.session("rita", .ReadWrite, "g1"), "CALL db.labels() YIELD label RETURN label");
    try wd.expectRuns(ga, try w.session("rita", .ReadWrite, null), "USE GRAPH g2; CALL db.labels() YIELD label RETURN label");
    try wd.expectRuns(ga, try w.session("rita", .ReadWrite, null), "CALL db.labels() YIELD label RETURN label");
    // A `*` deny still refuses it everywhere.
    try w.policy("no_reads", "*", &read, .deny);
    try wd.expectDenied(ga, try w.session("rita", .ReadWrite, null), "USE GRAPH g2; CALL db.labels() YIELD label RETURN label");
    try wd.expectDenied(ga, try w.session("rita", .ReadWrite, null), "CALL db.labels() YIELD label RETURN label");
}

test "SONNY-2753: a deny scoped to g1 covers g1 and its nodes and edges, not another graph's, nor a procedure as such" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_writes_g1", "g1", &write, .deny);
    const rw = wd.principal("rita", &.{"ReadWrite"}, 0);
    try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .graph = "g1" }));
    try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .node = .{ .graph = "g1", .id = 1 } }));
    try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .edge = .{ .graph = "g1", .id = 1 } }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .graph = "g2" }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .node = .{ .graph = "g2", .id = 1 } }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .edge = .{ .graph = D, .id = 1 } }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .procedure = "geode.ts.insert" }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .graph = "g2" }));
    try testing.expect(gps.writePermittedOn(testing.allocator, &rw, "g2"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &rw, "g1"));
}

test "SONNY-2753: a change of every graph at once is refused by a deny on any graph; a `*` deny refuses everything" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const rw = wd.principal("rita", &.{"ReadWrite"}, 0);
    const admin = wd.principal("ada", &.{"Admin"}, 0);
    try testing.expect(gps.writePermitted(testing.allocator, &rw));
    try testing.expect(session_graph.maySchemaDatabase(&admin));

    // A self-locking procedure (geode.tenant.backfill_edge_tags) writes every
    // graph: a deny on g1 refuses it.
    try w.policy("no_writes_g1", "g1", &write, .deny);
    try testing.expect(!gps.writePermitted(testing.allocator, &rw));
    try testing.expect(!gps.writePermitted(testing.allocator, &admin));
    // Index, constraint and schema DDL bind every graph: a DENY SCHEMA on g1
    // refuses them, and schema on g1 itself; g2's own schema stays.
    try w.policy("no_schema_g1", "g1", &schema_a, .deny);
    try testing.expect(!session_graph.maySchemaDatabase(&admin));
    try testing.expect(!session_graph.maySchema(&admin, "g1"));
    try testing.expect(session_graph.maySchema(&admin, "g2"));

    try w.drop("no_writes_g1");
    try w.drop("no_schema_g1");
    try testing.expect(gps.writePermitted(testing.allocator, &rw));
    try testing.expect(session_graph.maySchemaDatabase(&admin));

    try w.policy("no_writes", "*", &write, .deny);
    for ([_][]const u8{ "g1", "g2", D }) |g| {
        try testing.expect(!gps.writePermittedOn(testing.allocator, &rw, g));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &admin, g));
    }
    try testing.expect(!gps.writePermitted(testing.allocator, &rw));
    try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .procedure = "geode.ts.insert" }));
    try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .node = .{ .graph = "g2", .id = 1 } }));
}

test "SONNY-2753: gRPC: a DENY SCHEMA on g1 refuses database-wide schema DDL and g1's own, not g2's graph DDL" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const st = wd.graph_store.getGlobalStore(testing.allocator);
    try w.policy("no_schema_g1", "g1", &schema_a, .deny);
    const s = try w.session("ada", .Admin, "g2");
    try wd.expectDenied(ga, s, "CREATE INDEX idx2753 FOR (n:C) ON (n.v)");
    try wd.expectDenied(ga, s, "DROP GRAPH g1");
    try testing.expect(st.graphExists("g1"));
    try wd.expectRuns(ga, s, "CREATE GRAPH g3");
    try testing.expect(st.graphExists("g3"));
}

test "SONNY-2753: gRPC: an ALLOW WRITE scoped to g1 lets a readonly user write g1 and nothing else; a deny on g1 beats it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.grant("otto", "g1", wd.READ);
    try w.grant("otto", "g2", wd.READ);
    try w.policy("otto_writes_g1", "g1", &write, .allow);
    try wd.expectRuns(ga, try w.session("otto", .ReadOnly, null), "USE GRAPH g1; CREATE (:P {v: 1})");
    try wd.expectDenied(ga, try w.session("otto", .ReadOnly, null), "USE GRAPH g2; CREATE (:P {v: 2})");
    try wd.expectDenied(ga, try w.session("otto", .ReadOnly, null), "CREATE (:P {v: 3})");
    const ro = wd.principal("otto", &.{"ReadOnly"}, 0);
    try testing.expect(!gps.writePermitted(testing.allocator, &ro));

    try w.policy("no_writes_g1", "g1", &write, .deny);
    try wd.expectDenied(ga, try w.session("otto", .ReadOnly, null), "USE GRAPH g1; CREATE (:P {v: 4})");
    try testing.expectEqual(@as(usize, 1), wd.countIn("g1", "P"));
    try testing.expectEqual(@as(usize, 0), wd.countIn("g2", "P"));
    try testing.expectEqual(@as(usize, 0), wd.countIn(D, "P"));
}

test "SONNY-2753: with the decision cache on, a g1 verdict is never served for g2" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var cache = wd.decision_cache.DecisionCache.init(testing.allocator, wd.decision_cache.DEFAULT_CAPACITY);
    defer cache.deinit();
    const prev_cache = wd.decision_cache.getGlobalCache();
    wd.decision_cache.setGlobalCache(&cache);
    defer if (prev_cache) |c| wd.decision_cache.setGlobalCache(c) else wd.decision_cache.clearGlobalCache();

    try w.policy("no_writes_g1", "g1", &write, .deny);
    const rw = wd.principal("rita", &.{"ReadWrite"}, 9);
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .graph = "g1" }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .graph = "g2" }));
        try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .write, .{ .node = .{ .graph = "g1", .id = 1 } }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .node = .{ .graph = "g2", .id = 1 } }));
    }
    try testing.expect(cache.getHits() > 0);
}

test "SONNY-2753: a DENY DECRYPT_FIELD scoped to g1 refuses decryption in g1 only" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_decrypt_g1", "g1", &decrypt, .deny);
    const admin = wd.principal("ada", &.{"Admin"}, 0);
    try testing.expectEqual(Kind.deny, try wd.decideKind(&admin, .decrypt_field, .{ .node = .{ .graph = "g1", .id = 7 } }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&admin, .decrypt_field, .{ .node = .{ .graph = "g2", .id = 7 } }));
    try testing.expectEqual(Kind.allow, try wd.decideKind(&admin, .decrypt_field, .{ .node = .{ .graph = D, .id = 7 } }));
}
