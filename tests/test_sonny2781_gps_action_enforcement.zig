// SONNY-2781: every action a GPS policy can name is enforced, or the policy
// is refused. A deny naming one action stops exactly the statements that
// need it, on the graphs it covers.
//
// Enforcement only ever asked `gps.decide` about `.write` (one gate for all
// DML and DDL), `.read` / `.write` on a procedure, `.decrypt_field`,
// `.bind_graph` and `.admin_tenant`, and the handlers' read gate skipped
// `decide` for every principal whose builtin role holds Read. So a DENY READ
// did not stop a plain MATCH, and a DENY CREATE, UPDATE or DELETE stopped
// nothing (`execution.checkPermission`, the only other caller, had none). A
// DENY UNWRAP_KEY is asked by nothing.
//
// Now the statement's actions come from the one write walk that also
// decides the lock and the read-only floor (`write_walk.Actions`,
// `StatementPlan.actions`): the write gate asks CREATE for CREATE / INSERT /
// MERGE, UPDATE for SET / REMOVE / a MERGE's ON MATCH SET, DELETE for DELETE,
// WRITE and SCHEMA for DDL, and WRITE with CREATE, UPDATE and DELETE for a
// change no finer action names; WRITE is the umbrella (a DENY WRITE matches
// all of them, an ALLOW WRITE allows all but SCHEMA). The read gate asks
// MATCH (which a READ or MATCH policy matches) on every graph a program
// touches, EXPLAIN's included, for every principal. A deny naming
// UNWRAP_KEY is refused when it is added.
//
// Through the in-process gRPC Execute handler with authorization on, deny
// and allow policies installed through the real `PolicyCatalog`.
//
// CANARY: REQ=REQ-SONNY-2781-GPS-ACTION-ENFORCEMENT; FEATURE="GPS Policy Evaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2781_gps_action_enforcement.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const wd = @import("sonny2753_gps_world.zig");

const gps = wd.gps;
const Kind = wd.Kind;
const World = wd.World;
const Role = wd.Role;
const A = wd.policy_catalog.Action;
const D = wd.graph_store.DEFAULT_GRAPH_NAME;

const read = [_]A{.read};
const match = [_]A{.match_};
const create = [_]A{.create};
const update = [_]A{.update};
const delete = [_]A{.delete};
const schema_a = [_]A{.schema};
const write = [_]A{.write};

/// Each statement runs in a fresh session of `user` (`role`) that starts on
/// `graph`: a USE GRAPH that runs moves its session.
fn denied(w: *World, user: []const u8, role: Role, graph: ?[]const u8, queries: []const []const u8) !void {
    for (queries) |q| try wd.expectDenied(w.ga(), try w.session(user, role, graph), q);
}

fn runs(w: *World, user: []const u8, role: Role, graph: ?[]const u8, queries: []const []const u8) !void {
    for (queries) |q| try wd.expectRuns(w.ga(), try w.session(user, role, graph), q);
}

/// Every way a program reads a graph's data.
const reads = [_][]const u8{
    "MATCH (n:C) RETURN count(n) AS c",
    "PROFILE MATCH (n:C) RETURN n.v AS v",
    "EXPLAIN MATCH (n:C) RETURN n",
    "MATCH (n:C) RETURN n.v AS v UNION ALL MATCH (m:C) RETURN m.v AS v",
    "MATCH (n:C) WHERE EXISTS { MATCH (m:C) } RETURN count(n) AS c",
    "OPTIONAL MATCH (n:C) RETURN count(n) AS c",
    "MATCH (n:C) SET n.v = 1",
    "CALL db.labels() YIELD label RETURN label",
};

test "SONNY-2781: DENY READ on g1 stops every read of g1 (subqueries, UNION arms, EXPLAIN, PROFILE, a write's MATCH, procedures) and nothing on g2" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_reads_g1", "g1", &read, .deny);
    for ([_]struct { []const u8, Role }{ .{ "otto", .ReadOnly }, .{ "rita", .ReadWrite }, .{ "ada", .Admin } }) |u| {
        const rw = u[1] != .ReadOnly;
        for (reads) |q| {
            if (!rw and std.mem.indexOf(u8, q, "SET") != null) continue;
            try wd.expectDenied(w.ga(), try w.session(u[0], u[1], "g1"), q);
            try wd.expectRuns(w.ga(), try w.session(u[0], u[1], "g2"), q);
            try wd.expectRuns(w.ga(), try w.session(u[0], u[1], null), q);
        }
        try denied(&w, u[0], u[1], null, &.{"USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c"});
        // A program that reads no store passes.
        try runs(&w, u[0], u[1], "g1", &.{"RETURN 1 AS x"});
    }
}

test "SONNY-2781: DENY MATCH on g1 stops reading g1's data, and nothing on g2" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_match_g1", "g1", &match, .deny);
    try denied(&w, "rita", .ReadWrite, "g1", &.{ "MATCH (n:C) RETURN count(n) AS c", "PROFILE MATCH (n:C) RETURN n.v AS v", "MATCH (n:C) SET n.v = 1" });
    try runs(&w, "rita", .ReadWrite, "g2", &.{ "MATCH (n:C) RETURN count(n) AS c", "PROFILE MATCH (n:C) RETURN n.v AS v" });
}

test "SONNY-2781: DENY CREATE on g1 stops CREATE, INSERT, MERGE and their PROFILE on g1 only; SET, REMOVE, DELETE and reads still run" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_create_g1", "g1", &create, .deny);
    try denied(&w, "rita", .ReadWrite, "g1", &.{
        "CREATE (:X {v: 1})",
        "INSERT (:X {v: 2})",
        "MERGE (:X {k: 1})",
        "PROFILE CREATE (:X {v: 3})",
        "MATCH (n:C) CREATE (n)-[:R]->(:X {v: 4})",
    });
    try testing.expectEqual(@as(usize, 0), wd.countIn("g1", "X"));
    try runs(&w, "rita", .ReadWrite, "g1", &.{
        "MATCH (n:C) RETURN count(n) AS c",
        "MATCH (n:C) SET n.v = 1",
        "MATCH (n:C) REMOVE n.v",
        "MATCH (n:C) DETACH DELETE n",
    });
    try runs(&w, "rita", .ReadWrite, "g2", &.{ "CREATE (:X {v: 5})", "MERGE (:X {k: 2})" });
    try testing.expectEqual(@as(usize, 2), wd.countIn("g2", "X"));
}

test "SONNY-2781: DENY UPDATE on g1 stops SET, REMOVE, MERGE ... ON MATCH SET and their PROFILE on g1 only; CREATE, MERGE, DELETE still run" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_update_g1", "g1", &update, .deny);
    try denied(&w, "rita", .ReadWrite, "g1", &.{
        "MATCH (n:C) SET n.v = 1",
        "MATCH (n:C) REMOVE n.v",
        "MERGE (n:C {v: 0}) ON MATCH SET n.w = 1",
        "PROFILE MATCH (n:C) SET n.v = 2",
    });
    try runs(&w, "rita", .ReadWrite, "g1", &.{
        "CREATE (:X {v: 1})",
        "MERGE (:Y {k: 1})",
        "MERGE (z:Z {k: 1}) ON CREATE SET z.v = 1",
        "MATCH (n:C) RETURN count(n) AS c",
        "MATCH (n:X) DELETE n",
    });
    try runs(&w, "rita", .ReadWrite, "g2", &.{"MATCH (n:C) SET n.v = 1"});
}

test "SONNY-2781: DENY DELETE on g1 stops DELETE, DETACH DELETE and their PROFILE on g1 only; CREATE and SET still run" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_delete_g1", "g1", &delete, .deny);
    try denied(&w, "rita", .ReadWrite, "g1", &.{
        "MATCH (n:C) DELETE n",
        "MATCH (n:C) DETACH DELETE n",
        "PROFILE MATCH (n:C) DETACH DELETE n",
    });
    try testing.expectEqual(@as(usize, 1), wd.countIn("g1", "C"));
    try runs(&w, "rita", .ReadWrite, "g1", &.{ "CREATE (:X {v: 1})", "MATCH (n:C) SET n.v = 1", "MATCH (n:C) RETURN count(n) AS c" });
    try runs(&w, "rita", .ReadWrite, "g2", &.{"MATCH (n:C) DETACH DELETE n"});
    try testing.expectEqual(@as(usize, 0), wd.countIn("g2", "C"));
}

test "SONNY-2781: DENY SCHEMA on g1 stops DDL on g1; data changes on g1 still run" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_schema_g1", "g1", &schema_a, .deny);
    try denied(&w, "ada", .Admin, "g1", &.{ "CREATE INDEX i2781 FOR (n:C) ON (n.v)", "DROP GRAPH g1", "CREATE GRAPH TYPE t2781" });
    try runs(&w, "ada", .Admin, "g1", &.{ "CREATE (:X {v: 1})", "MATCH (n:C) SET n.v = 1", "MATCH (n:C) RETURN count(n) AS c" });
    try testing.expect(wd.graph_store.getGlobalStore(testing.allocator).graphExists("g1"));
}

test "SONNY-2781: DENY WRITE on g1 is the umbrella: every change on g1 is stopped, reads are not" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.policy("no_writes_g1", "g1", &write, .deny);
    try denied(&w, "ada", .Admin, "g1", &.{
        "CREATE (:X {v: 1})",
        "MERGE (:X {k: 1})",
        "MATCH (n:C) SET n.v = 1",
        "MATCH (n:C) DETACH DELETE n",
        "CREATE INDEX i2781w FOR (n:C) ON (n.v)",
        "PROFILE CREATE (:X {v: 2})",
    });
    try runs(&w, "ada", .Admin, "g1", &.{ "MATCH (n:C) RETURN count(n) AS c", "PROFILE MATCH (n:C) RETURN n.v AS v" });
}

test "SONNY-2781: an allow naming one action lets a principal with no role do exactly that on its graph" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // READ on g1: a data change reads the graph it changes (the read gate).
    try w.grant("nora", "g1", wd.READ);
    try w.policy("nora_creates_g1", "g1", &create, .allow);
    try runs(&w, "nora", .None, "g1", &.{"CREATE (:N {v: 1})"});
    try denied(&w, "nora", .None, "g1", &.{ "MATCH (n:C) SET n.v = 1", "MATCH (n:C) DETACH DELETE n", "CREATE INDEX i2781n FOR (n:C) ON (n.v)" });
    try denied(&w, "nora", .None, "g2", &.{"CREATE (:N {v: 2})"});
    try testing.expectEqual(@as(usize, 1), wd.countIn("g1", "N"));

    try w.drop("nora_creates_g1");
    try w.policy("nora_updates_g1", "g1", &update, .allow);
    try runs(&w, "nora", .None, "g1", &.{"MATCH (n:C) SET n.v = 1"});
    try denied(&w, "nora", .None, "g1", &.{ "CREATE (:N {v: 3})", "MATCH (n:C) DETACH DELETE n" });

    try w.drop("nora_updates_g1");
    try w.policy("nora_deletes_g1", "g1", &delete, .allow);
    try runs(&w, "nora", .None, "g1", &.{"MATCH (n:N) DETACH DELETE n"});
    try denied(&w, "nora", .None, "g1", &.{ "CREATE (:N {v: 4})", "MATCH (n:C) SET n.v = 2" });
    try testing.expectEqual(@as(usize, 0), wd.countIn("g1", "N"));
}

test "SONNY-2781: with the decision cache on, a verdict for one action is never served for another" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var cache = wd.decision_cache.DecisionCache.init(testing.allocator, wd.decision_cache.DEFAULT_CAPACITY);
    defer cache.deinit();
    const prev_cache = wd.decision_cache.getGlobalCache();
    wd.decision_cache.setGlobalCache(&cache);
    defer if (prev_cache) |c| wd.decision_cache.setGlobalCache(c) else wd.decision_cache.clearGlobalCache();

    try w.policy("no_delete_g1", "g1", &delete, .deny);
    const rw = wd.principal("rita", &.{"ReadWrite"}, 5);
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        try testing.expectEqual(Kind.deny, try wd.decideKind(&rw, .delete, .{ .graph = "g1" }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .create, .{ .graph = "g1" }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .update, .{ .graph = "g1" }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .write, .{ .graph = "g1" }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .match_, .{ .graph = "g1" }));
        try testing.expectEqual(Kind.allow, try wd.decideKind(&rw, .delete, .{ .graph = "g2" }));
    }
    try testing.expect(cache.getHits() > 0);
}

test "SONNY-2781: a tenant-scoped session reads and writes as before, and a deny applies to it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const t = try w.sessions.createSession("rita", "", .ReadWrite, "t2781", null, false, 0);
    try wd.expectRuns(ga, t, "CREATE (:T {v: 1})");
    try wd.expectRuns(ga, try w.sessions.createSession("rita", "", .ReadWrite, "t2781", null, false, 0), "MATCH (n:T) RETURN count(n) AS c");
    try w.policy("no_reads_default", D, &read, .deny);
    try wd.expectDenied(ga, try w.sessions.createSession("rita", "", .ReadWrite, "t2781", null, false, 0), "MATCH (n:T) RETURN count(n) AS c");
    try wd.expectRuns(ga, try w.sessions.createSession("rita", "", .ReadWrite, "t2781", "g2", false, 0), "MATCH (n:C) RETURN count(n) AS c");
}

test "SONNY-2781: a deny naming UNWRAP_KEY, which nothing enforces, is refused when added; an allow is accepted" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const unwrap = [_]A{.unwrap_key};
    const mixed = [_]A{ .write, .unwrap_key };
    for ([_][]const A{ &unwrap, &mixed }) |actions| {
        const spec: wd.policy_catalog.PolicySpec = .{ .name = "deny_unwrap", .scope_graph = "*", .actions = actions, .effect = .deny, .expression_source = "true", .enabled = true };
        try testing.expectError(error.PolicyActionNotEnforced, w.cat.addPolicyStrict(spec));
        try testing.expectError(error.PolicyActionNotEnforced, w.cat.addPolicy(spec));
    }
    try testing.expectEqual(@as(usize, 0), w.cat.listPolicies().len);
    try w.policy("allow_unwrap", "*", &unwrap, .allow);
    try testing.expectEqual(@as(usize, 1), w.cat.listPolicies().len);
}
