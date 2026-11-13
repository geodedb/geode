// SONNY-3245 regression: CREATE and INSERT patterns follow ISO/IEC
// 39075:2024 16.5 <insert graph pattern>, an unnamed node between two hops
// of a path is one node, and a null property value makes the property
// absent.
//
//   1. Refused with 42000 (`InvalidInsertPattern`), changing nothing:
//      - a variable the MATCH bound, given a label or a property
//        (SR 10 a) iii)): `MATCH (n) CREATE (n:Extra)` did nothing and
//        `CREATE (n {extra: 1})` changed the matched node;
//      - a later occurrence of a variable, given a label or a property
//        (SR 10 b)): `CREATE (a:R), (a:R)` made two nodes;
//      - an undirected inserted edge `-[:T]-` (stored a directed one) and a
//        type disjunction `[:T|U]` (stored a T edge): an <insert edge
//        pattern> points left or right (or is `~[ ]~`, Feature GH02, not
//        supported), and its <label set specification> joins with `&`.
//   2. `CREATE (a)-[:R]->(:M)-[:S]->(b)` makes one M (SR 2: one
//      system-generated variable per unnamed filler); it made two, so the
//      path did not exist. Also after a MATCH and in INSERT.
//   3. A null property value is absent: `CREATE (n {p: null})` and
//      `SET n.p = null` (nodes and relationships).
//   5. After a MATCH, `<-[:R]-` is stored pointing left (it was stored
//      left -> right whatever the arrow).
//   4. Pinned (already right on this branch): a chained MERGE returns its
//      row.
//
// Through the real gRPC handlers in process.
//
// CANARY: REQ=REQ-SONNY-3245-CREATE-FORMS; FEATURE="CreateStatement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3245_create_merge_forms.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

/// The first column of the first row as an integer (the query must run).
fn firstInt(ga: std.mem.Allocator, s: []const u8, q: []const u8) !?i64 {
    const resp = try fx.execute(ga, s, q);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        .schema => {},
        else => return null,
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| {
            if (p.rows.items.len == 0 or p.rows.items[0].values.items.len == 0) return null;
            const k = p.rows.items[0].values.items[0].kind orelse return null;
            return switch (k) {
                .int_val => |x| x.value,
                else => null,
            };
        },
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        else => return error.UnexpectedPayload,
    }
}

fn expectInt(ga: std.mem.Allocator, s: []const u8, q: []const u8, want: i64) !void {
    const got = (try firstInt(ga, s, q)) orelse -1;
    if (got != want) std.debug.print("'{s}' answers {d}; expected {d}\n", .{ q, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-3245: invalid CREATE and INSERT patterns are refused with 42000 and change nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3245r");

    try fx.expectRuns(ga, s, "CREATE (:A3245 {k: 1})");

    _ = try fx.expectRefused(ga, s, "MATCH (n:A3245) CREATE (n:Extra3245)", "42000");
    try expectInt(ga, s, "MATCH (n:Extra3245) RETURN count(n) AS c", 0);
    _ = try fx.expectRefused(ga, s, "MATCH (n:A3245) CREATE (n {extra: 1})", "42000");
    try expectInt(ga, s, "MATCH (n:A3245) WHERE n.extra IS NOT NULL RETURN count(n) AS c", 0);
    _ = try fx.expectRefused(ga, s, "MATCH (n:A3245) CREATE (n:Extra3245)-[:T3245]->(:Z3245)", "42000");
    try expectInt(ga, s, "MATCH (n:Z3245) RETURN count(n) AS c", 0);

    _ = try fx.expectRefused(ga, s, "CREATE (a:U3245)-[:T3245]-(b:V3245)", "42000");
    _ = try fx.expectRefused(ga, s, "INSERT (a:U3245)-[:T3245]-(b:V3245)", "42000");
    try expectInt(ga, s, "MATCH (n:U3245) RETURN count(n) AS c", 0);
    _ = try fx.expectRefused(ga, s, "CREATE (a:X3245)-[:T3245|U3245]->(b:Y3245)", "42000");
    try expectInt(ga, s, "MATCH (n:X3245) RETURN count(n) AS c", 0);

    _ = try fx.expectRefused(ga, s, "CREATE (a:R3245), (a:R3245)", "42000");
    _ = try fx.expectRefused(ga, s, "CREATE (a:R3245)-[:T3245]->(b:Q3245), (a {k: 2})", "42000");
    try expectInt(ga, s, "MATCH (n:R3245) RETURN count(n) AS c", 0);

    // Still accepted: a bound or repeated variable without a specification.
    try fx.expectRuns(ga, s, "CREATE (a:R2_3245), (a)");
    try expectInt(ga, s, "MATCH (n:R2_3245) RETURN count(n) AS c", 1);
    try fx.expectRuns(ga, s, "MATCH (n:A3245) CREATE (n)-[:T3245]->(:Z3245)");
    try expectInt(ga, s, "MATCH (:A3245)-[:T3245]->(z:Z3245) RETURN count(z) AS c", 1);
    try fx.expectRuns(ga, s, "CREATE (a:L3245)<-[:T3245]-(b:L3245)");
    try expectInt(ga, s, "MATCH (:L3245)-[r:T3245]->(:L3245) RETURN count(r) AS c", 1);
}

test "SONNY-3245: an unnamed node between two hops of a path is one node" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3245m");

    try fx.expectRuns(ga, s, "CREATE (:AA3245)-[:BB3245]->(:CC3245)-[:DD3245]->(:EE3245)");
    try expectInt(ga, s, "MATCH (n:CC3245) RETURN count(n) AS c", 1);
    try expectInt(ga, s, "MATCH (:AA3245)-[:BB3245]->(:CC3245)-[:DD3245]->(e:EE3245) RETURN count(e) AS c", 1);

    try fx.expectRuns(ga, s, "MATCH (a:AA3245) CREATE (a)-[:BB3245]->(:FF3245 {i: 1})-[:DD3245]->(:GG3245)<-[:HH3245]-(:II3245)");
    try expectInt(ga, s, "MATCH (n:FF3245) RETURN count(n) AS c", 1);
    try expectInt(ga, s, "MATCH (n:GG3245) RETURN count(n) AS c", 1);
    // `<-[:HH]-` points from II to GG (it was stored GG -> II after a MATCH).
    try expectInt(ga, s, "MATCH (:GG3245)<-[:HH3245]-(i:II3245) RETURN count(i) AS c", 1);
    try expectInt(ga, s, "MATCH (:AA3245)-[:BB3245]->(:FF3245)-[:DD3245]->(:GG3245)<-[:HH3245]-(i:II3245) RETURN count(i) AS c", 1);

    try fx.expectRuns(ga, s, "INSERT (:JJ3245)-[:BB3245]->(:KK3245)-[:DD3245]->(:LL3245)");
    try expectInt(ga, s, "MATCH (n:KK3245) RETURN count(n) AS c", 1);
}

test "SONNY-3245: a null property value is absent" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3245n");

    try fx.expectRuns(ga, s, "CREATE (n:P3245 {k: 1, p: null})");
    try expectInt(ga, s, "MATCH (n:P3245) RETURN size(keys(n)) AS c", 1);
    // `SET n.p = null` removes p through the same chokepoint
    // (`property_mutation.setNodePropertyFromValue` -> `removeNodeProperty`);
    // keys() no longer lists it (SONNY-6433: the read path copied the
    // removal's null tombstone into the property map).
    try fx.expectRuns(ga, s, "MATCH (n:P3245) SET n.k = null");
    try expectInt(ga, s, "MATCH (n:P3245) WHERE n.k IS NULL RETURN count(n) AS c", 1);
    try expectInt(ga, s, "MATCH (n:P3245) RETURN size(keys(n)) AS c", 0);
    try fx.expectRuns(ga, s, "MATCH (n:P3245) SET n.q = null");
    try expectInt(ga, s, "MATCH (n:P3245) WHERE n.q IS NULL RETURN count(n) AS c", 1);
    try expectInt(ga, s, "MATCH (n:P3245) RETURN size(keys(n)) AS c", 0);

    try fx.expectRuns(ga, s, "CREATE (:E3245)-[:ER3245 {w: 1, z: null}]->(:E3245)");
    try expectInt(ga, s, "MATCH ()-[r:ER3245]->() RETURN size(keys(r)) AS c", 1);
    try fx.expectRuns(ga, s, "MATCH ()-[r:ER3245]->() SET r.w = null");
    try expectInt(ga, s, "MATCH ()-[r:ER3245]->() WHERE r.w IS NULL RETURN count(r) AS c", 1);
    try expectInt(ga, s, "MATCH ()-[r:ER3245]->() RETURN size(keys(r)) AS c", 0);
}

test "SONNY-3245: a chained MERGE returns its row" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3245c");

    inline for (0..2) |_| {
        try expectInt(ga, s, "MERGE (a:CA3245 {k: 1}) MERGE (b:CB3245 {k: 2}) RETURN a.k + b.k AS t", 3);
    }
    try expectInt(ga, s, "MATCH (n:CA3245) RETURN count(n) AS c", 1);
}
