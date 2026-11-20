// SONNY-2848 RED REPRODUCTION (not in the sharded aggregate; listed in
// docs/KNOWN_TEST_ISSUES.md): on a tenant-scoped session a subquery or an
// aggregate that runs after WITH, or an aggregate over a subquery, sees none of
// the session's rows, while the same statement on an unscoped session is right.
//
// Root cause (not the tenant predicate): a session with a concrete tenant scope
// is demoted from the planned read runtime to the legacy executor
// (planned_read_runtime.zig, GAP-0846 demotion), and the legacy executor's
// single-pattern aggregate path (match_operations.zig executeMatchQueryImpl,
// the "pre-aggregate all matched nodes into a single row" branch) evaluates the
// RETURN's aggregates BEFORE the WITH, over `evaluateGroupAggregation`, which
// reads node properties only and cannot evaluate an expression (a subquery) in
// a row binding. The WITH then sees one row `{count}` and no `a`.
//
// The fixture and the oracle are the ones of
// tests/test_sonny6338_tenant_visibility_consistency.zig.
//
// CANARY: REQ=REQ-SONNY-2848-TENANT-SUBQUERY-AGGREGATION; FEATURE="ExpressionPathTenantScope"; ASPECT=RedReproduction; STATUS=IMPL; TEST=tests/test_sonny2848_tenant_subquery_aggregation.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const th = @import("sonny6338_tenant_harness.zig");

const Harness = th.Harness;

test "SONNY-2848: a subquery or an aggregate after WITH, and an aggregate over a subquery, count the session's rows" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    // C1: s1 -T-> s2;  C2: s3 -T-> s4;  U: s5 -T-> s6;  P: s7 (no edge).
    try h.exec(th.C1, "CREATE (a:S {who: 's1', k: 1})-[:T]->(b:S {who: 's2', k: 2})");
    try h.exec(th.C2, "CREATE (a:S {who: 's3', k: 3})-[:T]->(b:S {who: 's4', k: 4})");
    try h.exec(th.U, "CREATE (a:S {who: 's5', k: 5})-[:T]->(b:S {who: 's6', k: 6})");
    try h.exec(th.P, "CREATE (:S {who: 's7', k: 7})");

    const Case = struct { tenant: ?[]const u8, nodes: i64, sources: i64 };
    const cases = [_]Case{
        .{ .tenant = th.C1, .nodes = 2, .sources = 1 },
        .{ .tenant = th.U, .nodes = 2, .sources = 1 },
        .{ .tenant = th.P, .nodes = 5, .sources = 2 },
        .{ .tenant = null, .nodes = 7, .sources = 3 },
    };
    for (cases) |c| {
        // The oracle.
        h.expectInt(c.nodes, c.tenant, "MATCH (n:S) RETURN count(n)");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S)-[:T]->(b:S) RETURN count(a)");
        // The failing shapes.
        h.expectInt(c.sources, c.tenant, "MATCH (a:S) WITH a, COUNT { (a)-[:T]->() } AS d WHERE d > 0 RETURN count(a)");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S) WITH a WHERE EXISTS { (a)-[:T]->() } RETURN count(a)");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S) WITH a, size([(a)-[:T]->(x) | x.k]) AS d WHERE d > 0 RETURN count(a)");
        h.expectInt(c.sources, c.tenant, "MATCH (a:S) RETURN sum(COUNT { (a)-[:T]->() })");
        // The same defect with no subquery at all.
        h.expectInt(c.nodes, c.tenant, "MATCH (a:S) WITH a RETURN count(a)");
    }
    try testing.expectEqual(@as(usize, 0), h.mismatches);
}
