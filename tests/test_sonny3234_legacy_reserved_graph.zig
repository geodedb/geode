// SONNY-3234 (round 15, F10): a graph made under a name that SONNY-3191 has
// since reserved (CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH, HOME_GRAPH,
// HOME_PROPERTY_GRAPH) can be dropped by that name; the names stay refused
// for CREATE, and for DROP when no such graph exists.
//
// Round 14 reserved the names (42939): `CREATE GRAPH CURRENT_GRAPH` had made
// a graph USE GRAPH could never select. But a graph made so before the
// upgrade, loaded at start, could then never be dropped: DROP GRAPH
// CURRENT_GRAPH answered 42939 (and the quoted forms 42000). Now DROP GRAPH
// drops a graph of exactly that name when one exists, and logs it; the
// server warns at start for each such graph (`reservedNameGraphs`), and the
// CHANGELOG says how to remove them.
//
// CANARY: REQ=REQ-SONNY-3234-LEGACY-RESERVED-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3234_legacy_reserved_graph.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

/// A graph named `name`, made as a store before SONNY-3191 would have: in
/// the engine and in the registry, bypassing the reserved-name refusal.
fn injectLegacyGraph(st: *graph_store.GraphStore, name: []const u8) !void {
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    _ = try ad.getOrCreateGraph(name);
    try st.graphs.put(try st.allocator.dupe(u8, name), {});
}

test "SONNY-3234: a legacy graph named CURRENT_GRAPH is listed, and DROP GRAPH drops it; CREATE and a second DROP are refused (42939)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("legacy");
    try injectLegacyGraph(f.st, "CURRENT_GRAPH");
    try testing.expect(f.st.graphExists("CURRENT_GRAPH"));
    {
        // The start-up warning's list.
        const listed = try graph_store.reservedNameGraphs(f.st, testing.allocator);
        defer {
            for (listed) |n| testing.allocator.free(n);
            testing.allocator.free(listed);
        }
        try testing.expectEqual(@as(usize, 1), listed.len);
        try testing.expectEqualStrings("CURRENT_GRAPH", listed[0]);
    }
    // Before: 42939 for good.
    try fx.expectRuns(ga, s, "DROP GRAPH CURRENT_GRAPH");
    try testing.expect(!f.st.graphExists("CURRENT_GRAPH"));
    {
        const listed = try graph_store.reservedNameGraphs(f.st, testing.allocator);
        defer testing.allocator.free(listed);
        try testing.expectEqual(@as(usize, 0), listed.len);
    }
    // Gone: the name is refused again, for DROP and for CREATE.
    _ = try fx.expectRefused(ga, s, "DROP GRAPH CURRENT_GRAPH", "42939");
    _ = try fx.expectRefused(ga, s, "CREATE GRAPH CURRENT_GRAPH", "42939");
    _ = try fx.expectRefused(ga, s, "DROP GRAPH HOME_GRAPH", "42939");
    try testing.expect(!f.st.graphExists("CURRENT_GRAPH"));
    // The session serves on.
    try fx.expectRuns(ga, s, "RETURN 1 AS x");
}

test "SONNY-3234: with a legacy HOME_GRAPH present, CREATE GRAPH HOME_GRAPH is still refused and USE GRAPH HOME_GRAPH is the home graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("legacy-home");
    try injectLegacyGraph(f.st, "HOME_GRAPH");
    _ = try fx.expectRefused(ga, s, "CREATE GRAPH HOME_GRAPH", "42939");
    // The session's home graph, not the legacy one: a node made there is
    // not in the legacy graph.
    try fx.expectRuns(ga, s, "USE GRAPH HOME_GRAPH");
    try fx.expectRuns(ga, s, "CREATE (:H {v: 1})");
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "HOME_GRAPH", "H"));
    try fx.expectRuns(ga, s, "DROP GRAPH HOME_GRAPH");
    try testing.expect(!f.st.graphExists("HOME_GRAPH"));
}
