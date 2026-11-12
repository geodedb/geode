// SONNY-6338 / SONNY-2820 / SONNY-2848: every read a statement makes on behalf
// of a tenant-scoped session sees exactly the rows that session's MATCH sees.
//
// The rule (GAP-0846, `tenant_visibility.passesTenantFilterSlice`): a session
// of tenant T sees a row tagged T, and, when T is registered in the tenant
// hierarchy, a row tagged with any DESCENDANT of T. A child does not see its
// parent's rows, siblings do not see each other's, an unscoped (admin) session
// sees everything.
//
// Fixture, one graph:   P (parent) -> C1, C2 (children);  U (unrelated root).
//
//   * SONNY-6338: MERGE matched the EXACT tenant tag (crud_operations
//     `nodeMatchesPattern`, `collectCandidateNodeIds`, `edgeMatchesScopeAndType`),
//     so P's MERGE of a key C1 holds created a duplicate that P's MATCH then
//     returned twice. The node MERGE fast paths follow the executor's exact rule
//     (SONNY-2976), so they must decline a session whose tenant has descendants.
//   * SONNY-2820: knn() compared tenant tags exactly (eval.zig
//     `KnnScanScope.admits`), so P missed its children's rows; and a property
//     only hidden rows carry raised UnknownProperty instead of an empty list.
//   * SONNY-2848: the subquery forms the ticket names (COUNT {}, EXISTS {},
//     comprehensions, IN (subquery), shortestPath()) already see the session's
//     rows on this branch; they are pinned here. The shapes that still fail (a
//     subquery or an aggregate after WITH, an aggregate over a subquery) are
//     the red reproduction in tests/test_sonny2848_tenant_subquery_aggregation.zig.
//
// Every expected answer is computed from the same session's plain MATCH (the
// oracle), through the real parse -> execute pipeline; no mocks.
//
// CANARY: REQ=REQ-SONNY-6338-TENANT-VISIBILITY-CONSISTENCY; FEATURE="PerTenantIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6338_tenant_visibility_consistency.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const th = @import("sonny6338_tenant_harness.zig");

const Harness = th.Harness;
const expectTag = th.expectTag;
const P = th.P;
const C1 = th.C1;
const C2 = th.C2;
const U = th.U;

// ---------------------------------------------------------------------------
// SONNY-6338 (1): executor MERGE matches the session's MATCH-visible set.
// ---------------------------------------------------------------------------

fn checkNodeMerge(h: *Harness) !void {
    // C1 holds the key; P's MATCH sees it (GAP-0846).
    try testing.expectEqual(@as(i64, 1), try h.int(P, "MATCH (n:M {k: 1}) RETURN count(n)"));
    const c1_node = try h.nodeId("M", "c1");

    // P's MERGE of that key binds C1's node: no second node, the match set is
    // what P's MATCH returns, ON MATCH writes it as MATCH ... SET does, and its
    // tenant tag is unchanged.
    try testing.expectEqual(@as(i64, @intCast(c1_node)), try h.int(P, "MERGE (n:M {k: 1}) ON CREATE SET n.who = 'p' ON MATCH SET n.touched = 'p' RETURN id(n)"));
    try testing.expectEqual(@as(i64, 1), try h.int(P, "MATCH (n:M {k: 1}) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 1), try h.int(null, "MATCH (n:M {k: 1}) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 1), try h.int(P, "MATCH (n:M {k: 1}) WHERE n.touched = 'p' RETURN count(n)"));
    try expectTag(h, c1_node, C1);
    // The write oracle: P may write C1's row through MATCH ... SET as well.
    try h.exec(P, "MATCH (n:M {k: 1}) SET n.touched2 = 'p'");
    try testing.expectEqual(@as(i64, 1), try h.int(C1, "MATCH (n:M {k: 1}) WHERE n.touched2 = 'p' RETURN count(n)"));
    try expectTag(h, c1_node, C1);

    // Multi-property key, same rule.
    try testing.expectEqual(@as(i64, @intCast(try h.nodeId("M2", "c1"))), try h.int(P, "MERGE (n:M2 {a: 1, b: 'x'}) RETURN id(n)"));
    try testing.expectEqual(@as(i64, 1), try h.int(P, "MATCH (n:M2 {a: 1, b: 'x'}) RETURN count(n)"));

    // No leak: U, C2 and the siblings see nothing of C1's and create their own.
    try h.exec(U, "MERGE (n:M {k: 1}) ON CREATE SET n.who = 'u'");
    try testing.expectEqual(@as(i64, 1), try h.int(U, "MATCH (n:M {k: 1}) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 0), try h.int(U, "MATCH (n:M {k: 1}) WHERE n.who = 'c1' RETURN count(n)"));
    try h.exec(C2, "MERGE (n:M {k: 1}) ON CREATE SET n.who = 'c2'");
    try testing.expectEqual(@as(i64, 1), try h.int(C2, "MATCH (n:M {k: 1}) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 1), try h.int(C1, "MATCH (n:M {k: 1}) RETURN count(n)"));
    // P now sees C1's and C2's nodes (two children, two rows) and its MERGE
    // still creates nothing.
    try testing.expectEqual(@as(i64, 2), try h.int(P, "MATCH (n:M {k: 1}) RETURN count(n)"));
    try h.exec(P, "MERGE (n:M {k: 1})");
    try testing.expectEqual(@as(i64, 2), try h.int(P, "MATCH (n:M {k: 1}) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 3), try h.int(null, "MATCH (n:M {k: 1}) RETURN count(n)"));

    // A child does not see its parent's rows: P's own key is not C1's match.
    try h.exec(P, "MERGE (n:Q {k: 9}) ON CREATE SET n.who = 'p'");
    try h.exec(C1, "MERGE (n:Q {k: 9}) ON CREATE SET n.who = 'c1'");
    try testing.expectEqual(@as(i64, 1), try h.int(C1, "MATCH (n:Q {k: 9}) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 2), try h.int(P, "MATCH (n:Q {k: 9}) RETURN count(n)"));
    try h.exec(P, "MERGE (n:Q {k: 9})");
    try testing.expectEqual(@as(i64, 2), try h.int(P, "MATCH (n:Q {k: 9}) RETURN count(n)"));
}

fn checkRelationshipMerge(h: *Harness) !void {
    try testing.expectEqual(@as(i64, 1), try h.int(P, "MATCH (a:R {k: 1})-[:LINK]->(b:R {k: 2}) RETURN count(*)"));
    try h.exec(P, "MERGE (a:R {k: 1})-[:LINK]->(b:R {k: 2})");
    try testing.expectEqual(@as(i64, 1), try h.int(P, "MATCH (a:R {k: 1})-[:LINK]->(b:R {k: 2}) RETURN count(*)"));
    try testing.expectEqual(@as(i64, 2), try h.int(null, "MATCH (n:R) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 1), try h.int(null, "MATCH ()-[r:LINK]->() RETURN count(r)"));
    // U neither sees nor matches C1's relationship: it creates its own.
    try h.exec(U, "MERGE (a:R {k: 1})-[:LINK]->(b:R {k: 2})");
    try testing.expectEqual(@as(i64, 1), try h.int(U, "MATCH (a:R {k: 1})-[:LINK]->(b:R {k: 2}) RETURN count(*)"));
    try testing.expectEqual(@as(i64, 1), try h.int(C1, "MATCH (a:R {k: 1})-[:LINK]->(b:R {k: 2}) RETURN count(*)"));
    try testing.expectEqual(@as(i64, 2), try h.int(null, "MATCH ()-[r:LINK]->() RETURN count(r)"));
}

fn seedMerge(h: *Harness) !void {
    try h.exec(C1, "CREATE (:M {k: 1, who: 'c1'})");
    try h.exec(C1, "CREATE (:M2 {a: 1, b: 'x', who: 'c1'})");
    try h.exec(C1, "CREATE (a:R {k: 1})-[:LINK]->(b:R {k: 2})");
}

test "SONNY-6338: a parent's executor MERGE matches its child's node and relationship (MATCH is the oracle)" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seedMerge(&h);
    try checkNodeMerge(&h);
    try checkRelationshipMerge(&h);
}

test "SONNY-6338: the same after a clean reopen and under strict tenancy" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try seedMerge(&h);
    try h.reopen();
    try checkNodeMerge(&h);
    try checkRelationshipMerge(&h);
}

test "SONNY-6338: the node MERGE fast paths decline a session whose tenant has descendants" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    // The fast-path primitives match the exact tenant tag (SONNY-2976), which is
    // the visible set only for a tenant with no descendants.
    var p = h.ctxFor(P);
    var c1 = h.ctxFor(C1);
    var u = h.ctxFor(U);
    var admin = h.ctxFor(null);
    try testing.expect(!geode.bulk_ingest.sessionAllowsTenantScopedNodeMerges(&p));
    try testing.expect(geode.bulk_ingest.sessionAllowsTenantScopedNodeMerges(&c1));
    try testing.expect(geode.bulk_ingest.sessionAllowsTenantScopedNodeMerges(&u));
    try testing.expect(geode.bulk_ingest.sessionAllowsTenantScopedNodeMerges(&admin));
}

// ---------------------------------------------------------------------------
// SONNY-2820: knn() sees what MATCH sees.
// ---------------------------------------------------------------------------

fn sameIds(want: []const u64, got: []const u64) !void {
    if (!std.mem.eql(u64, want, got)) {
        std.debug.print("knn ids: want {any}, got {any}\n", .{ want, got });
        return error.KnnIdsDiffer;
    }
}

fn checkKnn(h: *Harness, index: bool) !void {
    // Distances to [0, 1]: u 0.0 (nearest, hidden from P/C1/C2), p 0.2,
    // c1 0.4, c2 0.6, c1b 1.0.
    try h.exec(U, "CREATE (:V {who: 'u', emb: vectorf32([0.0, 1.0]), uonly: vectorf32([1.0, 1.0])})");
    try h.exec(P, "CREATE (:V {who: 'p', emb: vectorf32([0.0, 1.2])})");
    try h.exec(C1, "CREATE (:V {who: 'c1', emb: vectorf32([0.0, 1.4])})");
    try h.exec(C2, "CREATE (:V {who: 'c2', emb: vectorf32([0.0, 1.6])})");
    try h.exec(C1, "CREATE (:V {who: 'c1b', emb: vectorf32([0.0, 2.0])})");
    if (index) try h.exec(null, "CREATE INDEX v_emb ON V (emb) USING vector");
    const u = try h.nodeId("V", "u");
    const p = try h.nodeId("V", "p");
    const c1 = try h.nodeId("V", "c1");
    const c2 = try h.nodeId("V", "c2");
    const c1b = try h.nodeId("V", "c1b");

    // The oracle: what each session's MATCH sees.
    try testing.expectEqual(@as(i64, 4), try h.int(P, "MATCH (n:V) RETURN count(n)"));
    try testing.expectEqual(@as(i64, 2), try h.int(C1, "MATCH (n:V) RETURN count(n)"));

    const q = "RETURN knn('emb', vectorf32([0.0, 1.0]), 10, 'l2') AS ids";
    try sameIds(&.{ p, c1, c2, c1b }, try h.ids(P, q));
    try sameIds(&.{ c1, c1b }, try h.ids(C1, q));
    try sameIds(&.{c2}, try h.ids(C2, q));
    try sameIds(&.{u}, try h.ids(U, q));
    try sameIds(&.{ u, p, c1, c2, c1b }, try h.ids(null, q));
    // Top-k with the nearest row hidden: k visible rows, nearest first.
    try sameIds(&.{ p, c1 }, try h.ids(P, "RETURN knn('emb', vectorf32([0.0, 1.0]), 2, 'l2') AS ids"));
    try sameIds(&.{c1}, try h.ids(C1, "RETURN knn('emb', vectorf32([0.0, 1.0]), 1, 'l2') AS ids"));
    // A property only rows hidden from the session carry: an empty list, as
    // when no row is near (never an error that depends on the hidden rows).
    try sameIds(&.{}, try h.ids(P, "RETURN knn('uonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids"));
    try sameIds(&.{}, try h.ids(C1, "RETURN knn('uonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids"));
    // ... and the same for a property no row carries at all, for a session
    // whose scope can hide rows (so the two cannot be told apart).
    try sameIds(&.{}, try h.ids(C1, "RETURN knn('nosuch', vectorf32([1.0, 1.0]), 5, 'l2') AS ids"));
    try sameIds(&.{u}, try h.ids(U, "RETURN knn('uonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids"));
}

test "SONNY-2820: knn() on the scan path returns the k nearest rows the session's MATCH sees" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try checkKnn(&h, false);
}

test "SONNY-2820: knn() on the vector-index path returns the k nearest rows the session's MATCH sees" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try checkKnn(&h, true);
}

// ---------------------------------------------------------------------------
// SONNY-2848: subqueries see what MATCH sees.
// ---------------------------------------------------------------------------

fn checkSubqueries(h: *Harness) !void {
    // C1: s1 -T-> s2;  C2: s3 -T-> s4;  U: s5 -T-> s6;  P: s7 (no edge).
    try h.exec(C1, "CREATE (a:S {who: 's1', k: 1})-[:T]->(b:S {who: 's2', k: 2})");
    try h.exec(C2, "CREATE (a:S {who: 's3', k: 3})-[:T]->(b:S {who: 's4', k: 4})");
    try h.exec(U, "CREATE (a:S {who: 's5', k: 5})-[:T]->(b:S {who: 's6', k: 6})");
    try h.exec(P, "CREATE (:S {who: 's7', k: 7})");

    const Case = struct { tenant: ?[]const u8, nodes: i64, sources: i64 };
    const cases = [_]Case{
        .{ .tenant = C1, .nodes = 2, .sources = 1 },
        .{ .tenant = U, .nodes = 2, .sources = 1 },
        .{ .tenant = P, .nodes = 5, .sources = 2 },
        .{ .tenant = null, .nodes = 7, .sources = 3 },
    };
    for (cases) |c| {
        // The oracle.
        h.expectInt(c.nodes, c.tenant, "MATCH (n:S) RETURN count(n)");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S)-[:T]->(b:S) RETURN count(a)");
        // Uncorrelated COUNT {} / EXISTS {}.
        h.expectInt(c.nodes, c.tenant, "RETURN COUNT { (n:S) } AS c");
        h.expectInt(1, c.tenant, "RETURN EXISTS { (n:S) } AS e");
        // Correlated, from a MATCH row.
        h.expectInt(c.sources, c.tenant, "MATCH (a:S) WHERE EXISTS { (a)-[:T]->(b) } RETURN count(a)");
        h.expectInt(c.nodes, c.tenant, "MATCH (a:S) WHERE COUNT { (n:S) } > 0 RETURN count(a)");
        // Pattern comprehension.
        h.expectInt(c.sources, c.tenant, "RETURN size([(a:S)-[:T]->(b:S) | b.who]) AS c");
        // IN (subquery).
        h.expectInt(c.nodes, c.tenant, "MATCH (x:S) WHERE x.k IN (MATCH (y:S) RETURN y.k) RETURN count(x)");
        // shortestPath() in an expression, within the session's rows.
        h.expectInt(c.sources, c.tenant, "MATCH (a:S)-[:T]->(b:S) RETURN count(shortestPath((a)-[*]-(b)))");
        // A WITH aggregate, a correlated EXISTS under count(*), IN from a hop.
        h.expectInt(c.nodes, c.tenant, "MATCH (a:S) WITH count(a) AS c RETURN c");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S) WHERE EXISTS { (a)-[:T]->() } RETURN count(*)");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S)-[:T]->(b:S) WHERE b.k IN (MATCH (y:S) RETURN y.k) RETURN count(a)");
    }
}

test "SONNY-2848: COUNT {}, EXISTS {}, comprehensions, IN (subquery) and shortestPath() see the session's MATCH rows" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try checkSubqueries(&h);
    try testing.expectEqual(@as(usize, 0), h.mismatches);
}

test "SONNY-2848: the same under strict tenancy (admin excluded: strict refuses an unscoped read)" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try h.exec(C1, "CREATE (a:S {who: 's1', k: 1})-[:T]->(b:S {who: 's2', k: 2})");
    try h.exec(P, "CREATE (:S {who: 's7', k: 7})");
    try testing.expectEqual(@as(i64, 2), try h.int(C1, "RETURN COUNT { (n:S) } AS c"));
    try testing.expectEqual(@as(i64, 3), try h.int(P, "RETURN COUNT { (n:S) } AS c"));
    try testing.expectEqual(@as(i64, 1), try h.int(C1, "MATCH (a:S) WHERE EXISTS { (a)-[:T]->(b) } RETURN count(a)"));
    try testing.expectEqual(@as(i64, 3), try h.int(P, "MATCH (x:S) WHERE x.k IN (MATCH (y:S) RETURN y.k) RETURN count(x)"));
}
