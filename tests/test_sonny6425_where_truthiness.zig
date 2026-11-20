// SONNY-6425 items 1 and 2: a WHERE / FILTER / HAVING keeps a row only when
// its search condition is True, on a single node and on a cluster leader
// alike, and a WHERE or SET expression that fails to evaluate answers the
// same error on both.
//
// ISO/IEC 39075:2024 19.1 <search condition>, General Rule 2: "A <search
// condition> is said to be satisfied if and only if the result of the
// <boolean value expression> is True"; 16.13 <where clause>, General Rule
// 2b: a record is added to the result "If INCLUDE is True". 20.20 Syntax
// Rule 3 makes a non-Boolean predicand a type error; this engine has no
// static types for property values, so a value that is not the Boolean True
// (an integer, a string, null, False) keeps no row, the rule SONNY-3184
// (6d921942) applied to the initial-WITH dispatcher and the cluster leader's
// MATCH ... SET already applies. The single-node MATCH, FILTER, HAVING,
// WITH ... WHERE and planned-read paths took a non-zero integer as true.
//
// Item 2: the leader's replicated MATCH ... SET (`clusterReplicateMatchSet`)
// answered `ClusterWriteNotReplicable` (40001, "retry") for a WHERE or SET
// expression that failed to evaluate; a single node answers the
// expression's own error.
//
// Real parse -> execute pipeline on a persisted store, and an in-process
// 3-node raft cluster (the SONNY-3348 fixture) for the leader. No mocks.
//
// CANARY: REQ=REQ-SONNY-6425-WHERE-TRUTHINESS; FEATURE="SearchConditionTruth"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6425_where_truthiness.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");
const c = @import("sonny3348_cluster_harness.zig");

const cluster_mod = geode.distributed.cluster;
const raft_apply = geode.distributed.raft_apply;
const graph_store = geode.graph_store;

fn seed(s: *h.Session) !void {
    try s.execAs(null, "CREATE (:W6425 {k: 1, a: 1, z: 0, s: 'x'})-[:R6425 {w: 1}]->(:W6425 {k: 2, a: 2, z: 0, s: 'y'})");
}

/// Statements whose search condition is a non-zero integer (or another
/// non-Boolean value): each keeps no row.
const no_row_queries = [_][]const u8{
    "MATCH (n:W6425) WHERE n.a RETURN n.k",
    "MATCH (n:W6425) WHERE n.a RETURN count(n) AS c",
    "MATCH (n:W6425) WHERE n.a RETURN n.k AS k ORDER BY k",
    "MATCH (n:W6425) WHERE n.a RETURN n.k LIMIT 5",
    "MATCH (n:W6425 {k: 1}) WHERE n.a RETURN n.k",
    "MATCH (n:W6425) WHERE n.s RETURN n.k",
    "MATCH (n:W6425) FILTER n.a RETURN n.k",
    "MATCH (n:W6425)-[r:R6425]->(m:W6425) WHERE r.w RETURN n.k",
    "MATCH (n:W6425)-[r:R6425]->(m:W6425) WHERE n.a RETURN m.k",
    "MATCH (n:W6425), (m:W6425) WHERE n.a RETURN n.k, m.k",
    "MATCH (n:W6425) WITH n WHERE n.a RETURN n.k",
    "MATCH (n:W6425) RETURN n.k AS k, count(*) AS c GROUP BY n.k HAVING c",
};

/// The Boolean controls: unchanged.
const control_queries = [_]struct { q: []const u8, want: []const []const u8 }{
    .{ .q = "MATCH (n:W6425) WHERE n.a = 1 RETURN n.k", .want = &.{"1"} },
    .{ .q = "MATCH (n:W6425) WHERE n.a > 0 RETURN n.k", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (n:W6425) FILTER n.a = 2 RETURN n.k", .want = &.{"2"} },
    .{ .q = "MATCH (n:W6425)-[r:R6425]->(m:W6425) WHERE r.w = 1 RETURN n.k", .want = &.{"1"} },
    .{ .q = "MATCH (n:W6425) RETURN n.k AS k, count(*) AS c GROUP BY n.k HAVING c = 1", .want = &.{ "1|1", "2|1" } },
};

test "SONNY-6425 item 1: on a single node a WHERE / FILTER / HAVING keeps a row only when it is True" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    try seed(&s);
    var f: h.Failures = .{};
    for (no_row_queries) |q| {
        const want: []const []const u8 = if (std.mem.indexOf(u8, q, "count(n) AS c") != null) &.{"0"} else &.{};
        try h.expectRows(&s, &f, q, want);
    }
    for (control_queries) |cq| try h.expectRows(&s, &f, cq.q, cq.want);
    // A write gated by an integer WHERE writes nothing.
    try s.execAs(null, "MATCH (n:W6425) WHERE n.a SET n.t = 1");
    try h.expectRows(&s, &f, "MATCH (n:W6425) WHERE n.t = 1 RETURN n.k", &.{});
    try f.finish("single-node search condition");
}

/// The error a statement raises on this session, or "ok".
fn outcome(s: *h.Session, q: []const u8) []const u8 {
    s.execAs(null, q) catch |err| return @errorName(err);
    return "ok";
}

const error_statements = [_][]const u8{
    "MATCH (n:W6425) WHERE n.a / n.z = 1 SET n.e = 1",
    "MATCH (n:W6425) SET n.e = n.a / n.z",
};

const leader_statements = [_][]const u8{
    // Item 1 on the leader: an integer WHERE keeps no row (already so).
    "MATCH (n:W6425) WHERE n.a SET n.t = 1",
    // A Boolean WHERE writes, as on a single node.
    "MATCH (n:W6425) WHERE n.a = 1 SET n.b = 1",
};

test "SONNY-6425 items 1-2: a cluster leader's MATCH ... SET keeps the same rows and answers the same errors as a single node" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    h.silenceEngineLogs();
    var f: h.Failures = .{};
    var ga = std.heap.ArenaAllocator.init(testing.allocator);
    defer ga.deinit();
    const aa = ga.allocator();

    // The reference: a single node.
    var single_errors: [error_statements.len][]const u8 = undefined;
    {
        var s = try h.Session.init(.no_policy);
        defer s.deinit();
        try seed(&s);
        for (error_statements, 0..) |q, i| single_errors[i] = try aa.dupe(u8, outcome(&s, q));
        for (leader_statements) |q| try s.execAs(null, q);
        var f1: h.Failures = .{};
        try h.expectRows(&s, &f1, "MATCH (n:W6425) WHERE n.t = 1 RETURN n.k", &.{});
        try h.expectRows(&s, &f1, "MATCH (n:W6425) WHERE n.b = 1 RETURN n.k", &.{"1"});
        try h.expectRows(&s, &f1, "MATCH (n:W6425) WHERE n.e IS NOT NULL RETURN n.k", &.{});
        // Carried over (copied out of the session's arena) so the leader's
        // checks still run.
        for (f1.items.items) |msg| try f.add(aa, "single-node reference: {s}", .{msg});
    }
    for (single_errors, error_statements) |e, q| {
        if (std.mem.eql(u8, e, "ok")) try f.add(aa, "single node: {s}: expected an evaluation error, it succeeded", .{q});
    }

    // The leader.
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    try seed(&s);
    raft_apply.setGlobalStore(graph_store.getGlobalStore(testing.allocator));
    defer raft_apply.resetGlobalStore();
    var cl: c.Cluster = undefined;
    try cl.init(testing.allocator);
    defer cl.deinit();
    const deadline = c.nowMs() + 10_000;
    while (cl.leader.raft.committedIndex() == 0) {
        if (c.nowMs() > deadline) return error.NoCommit;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};
    }
    _ = try cl.settle();
    cluster_mod.setGlobalClusterCoordinator(cl.leader);
    defer cluster_mod.clearGlobalClusterCoordinator();

    for (error_statements, single_errors) |q, want| {
        const got = outcome(&s, q);
        if (!std.mem.eql(u8, got, want)) try f.add(aa, "leader: {s}: answered {s}, a single node answers {s}", .{ q, got, want });
    }
    const before = try cl.settle();
    for (leader_statements) |q| try s.execAs(null, q);
    const after = try cl.settle();
    if (after <= before) try f.add(aa, "leader: the SET statements were not proposed through raft", .{});
    try h.expectRows(&s, &f, "MATCH (n:W6425) WHERE n.t = 1 RETURN n.k", &.{});
    try h.expectRows(&s, &f, "MATCH (n:W6425) WHERE n.b = 1 RETURN n.k", &.{"1"});
    try h.expectRows(&s, &f, "MATCH (n:W6425) WHERE n.e IS NOT NULL RETURN n.k", &.{});
    try f.finish("cluster leader parity");
}
