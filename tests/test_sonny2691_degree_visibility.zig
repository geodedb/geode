// SONNY-2691 regression: indegree() / outdegree() crashed the server on a
// negative id and read the degree of any node, in any tenant, under any policy.
//
//   * `RETURN indegree(-1)` (and outdegree) reached `@intCast(i64 -> u64)`
//     (eval.zig:3260 / :3282): "integer does not fit in destination type",
//     a panic that aborts a ReleaseSafe server. Any reader could crash it.
//   * The raw-id form never resolved the node, so a tenant_a session got
//     `indegree(<tenant_b id>)` = 1, and a policy-hidden node's degree too.
//   * Both forms counted every edge in the node's adjacency, so a degree
//     counted the neighbours a policy hides (the degree half of SONNY-2685).
//
// The fix: an id that does not fit u64 names no node, so its degree is 0, the
// answer the functions already gave for any id that names no node. The node is
// resolved and must be visible to the session (its graph, its tenant scope and
// its RLS policies); a hidden or foreign node behaves as absent (0). The count
// includes exactly the edges a traversal from the node may take
// (`HopScope.stepAllowed`, SONNY-2679): the edge is in the graph and the tenant
// scope, and the neighbour is visible.
//
// The fixture, for every session (`leak` is the node the session may not see):
//
//     g1:G --R--> ok        ok --R--> g1
//     g1:G --R--> leak      leak --R--> g1
//
// CANARY: REQ=REQ-SONNY-2691-DEGREE-VISIBILITY; FEATURE="NodeDegreeFunctions"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2691_degree_visibility.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;

fn seed(s: *h.Session) !void {
    const owner: ?[]const u8 = if (s.mode == .tenant_scoped) h.tenant_a else null;
    try s.execAs(owner, "CREATE (:G {s: 'g1'})");
    try s.execAs(owner, "CREATE (:Doc {s: 'ok', cls: 'public'})");
    switch (s.mode) {
        .no_policy, .label_policy => try s.execAs(null, "CREATE (:Hidden {s: 'leak', cls: 'secret'})"),
        .expr_policy => try s.execAs(null, "CREATE (:Doc {s: 'leak', cls: 'secret'})"),
        .tenant_scoped => try s.execAs(h.tenant_b, "CREATE (:Doc {s: 'leak', cls: 'secret'})"),
    }
    const store = graph_store.getGlobalStore(testing.allocator);
    const g1 = try s.idOf("g1");
    const ok = try s.idOf("ok");
    const leak = try s.idOf("leak");
    // The edges carry the reader's own tenant tag, so in the tenant mode only
    // the node check keeps `leak` out of the count.
    const edge_tenant = if (s.mode == .tenant_scoped) h.tenant_a else graph_store.DEFAULT_TENANT_ID;
    _ = try store.createEdgeWithGraphAndTenant(g1, ok, "R", graph_store.DEFAULT_GRAPH_NAME, edge_tenant);
    _ = try store.createEdgeWithGraphAndTenant(ok, g1, "R", graph_store.DEFAULT_GRAPH_NAME, edge_tenant);
    _ = try store.createEdgeWithGraphAndTenant(g1, leak, "R", graph_store.DEFAULT_GRAPH_NAME, edge_tenant);
    _ = try store.createEdgeWithGraphAndTenant(leak, g1, "R", graph_store.DEFAULT_GRAPH_NAME, edge_tenant);
    try s.restrict("Hidden");
}

fn checkMode(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    try seed(&s);
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const open = mode == .no_policy;

    const g1 = try s.idOf("g1");
    const leak = try s.idOf("leak");

    // The node form: g1's neighbours are ok and leak, in each direction.
    try h.expectRows(&s, &f, "MATCH (g:G) RETURN outdegree(g)", &.{if (open) "2" else "1"});
    try h.expectRows(&s, &f, "MATCH (g:G) RETURN indegree(g)", &.{if (open) "2" else "1"});
    // The raw-id form counts the same edges.
    try h.expectRows(&s, &f, try std.fmt.allocPrint(aa, "RETURN outdegree({d})", .{g1}), &.{if (open) "2" else "1"});
    try h.expectRows(&s, &f, try std.fmt.allocPrint(aa, "RETURN indegree({d})", .{g1}), &.{if (open) "2" else "1"});
    // A hidden (or, in the tenant mode, foreign) node behaves as absent.
    try h.expectRows(&s, &f, try std.fmt.allocPrint(aa, "RETURN indegree({d})", .{leak}), &.{if (open) "1" else "0"});
    try h.expectRows(&s, &f, try std.fmt.allocPrint(aa, "RETURN outdegree({d})", .{leak}), &.{if (open) "1" else "0"});
    // An id no node has, at the top of the range.
    try h.expectRows(&s, &f, "RETURN indegree(9223372036854775807), outdegree(9223372036854775807)", &.{"0|0"});

    try f.finish(@tagName(mode));
}

test "SONNY-2691: with no policy and no tenant scope, the degree functions count every edge (unchanged)" {
    try checkMode(.no_policy);
}

test "SONNY-2691: under a label-deny policy, a hidden node has no degree and is no neighbour" {
    try checkMode(.label_policy);
}

test "SONNY-2691: under an expression policy, a hidden node has no degree and is no neighbour" {
    try checkMode(.expr_policy);
}

test "SONNY-2691: a tenant-scoped session reads no degree of another tenant's node, and counts no edge to it" {
    try checkMode(.tenant_scoped);
}

test "SONNY-2691: a node in another graph behaves as absent to the raw-id form" {
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const store = graph_store.getGlobalStore(testing.allocator);
    const a = try store.createNodeWithGraph(&[_][]const u8{"G"}, "g2");
    const b = try store.createNodeWithGraph(&[_][]const u8{"G"}, "g2");
    _ = try store.createEdgeWithGraphAndTenant(a, b, "R", "g2", graph_store.DEFAULT_TENANT_ID);
    try h.expectRows(&s, &f, try std.fmt.allocPrint(aa, "RETURN indegree({d}), outdegree({d})", .{ b, a }), &.{"0|0"});
    try f.finish("other graph");
}

// CANARY: REQ=REQ-SONNY-2691-DEGREE-RETAINS-NOTHING; FEATURE="NodeDegreeFunctions"; ASPECT=NoRetainedNodeCopies; STATUS=TESTED; TEST=tests/test_sonny2691_degree_visibility.zig; OWNER=security; UPDATED=2026-09-26
/// P11 (the SONNY-2686 security review): the raw-id form resolved its node
/// with `getNodePtrForScan`, which boxes a copy of the node into the store's
/// `scan_hydrated_nodes` on EVERY call, frees it only at the graph's next
/// checkpoint, and charges it to no read budget. So one read such as
/// `size([x IN range(1, N) | outdegree($id)])` grew the store by N node
/// copies (the review measured 1,999 for 2,000 calls, 3,998 in a tenant
/// session, where the traversal gate then copied every neighbour too), and
/// a large enough N exhausted memory; before SONNY-2691 the same call
/// allocated nothing. The node is now decided on a transient copy freed
/// before the call returns, and its adjacency is counted by id.
fn checkRetainsNothing(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    try seed(&s);
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const store = graph_store.getGlobalStore(testing.allocator);
    const g1 = try s.idOf("g1");
    const leak = try s.idOf("leak");
    const open = mode == .no_policy;

    const cases = [_]struct { func: []const u8, id: u64, want: []const u8 }{
        .{ .func = "outdegree", .id = g1, .want = if (open) "2" else "1" },
        .{ .func = "indegree", .id = g1, .want = if (open) "2" else "1" },
        // The node the session may not see: decided, then refused, 2,000 times.
        .{ .func = "outdegree", .id = leak, .want = if (open) "1" else "0" },
    };
    for (cases) |c| {
        const before = store.scan_hydrated_nodes.items.len;
        // 2,000 calls in one read: each list element evaluates the WHERE.
        const q = try std.fmt.allocPrint(aa, "RETURN size([x IN range(0, 2000) WHERE {s}({d}) = {s} | x]) AS n", .{ c.func, c.id, c.want });
        try h.expectRows(&s, &f, q, &.{"2000"});
        const after = store.scan_hydrated_nodes.items.len;
        if (after != before) {
            try f.add(aa, "[{s}] 2,000 calls of {s}({d}) left {d} node copies retained in the store (scan_hydrated_nodes {d} -> {d})", .{ @tagName(mode), c.func, c.id, after -| before, before, after });
        }
    }
    try f.finish(@tagName(mode));
}

test "SONNY-2691 (P11): 2,000 degree calls with no policy retain no node copy" {
    try checkRetainsNothing(.no_policy);
}

test "SONNY-2691 (P11): 2,000 degree calls under a label-deny policy retain no node copy" {
    try checkRetainsNothing(.label_policy);
}

test "SONNY-2691 (P11): 2,000 degree calls under an expression policy retain no node copy" {
    try checkRetainsNothing(.expr_policy);
}

test "SONNY-2691 (P11): 2,000 degree calls in a tenant-scoped session retain no node copy" {
    try checkRetainsNothing(.tenant_scoped);
}

// LAST on purpose: before the fix a negative id PANICS (safety-checked
// illegal behaviour), which aborts the test binary as it aborted the server.
test "SONNY-2691: a negative id is not a node: its degree is 0, in every session" {
    inline for (.{ h.Mode.no_policy, h.Mode.label_policy, h.Mode.expr_policy, h.Mode.tenant_scoped }) |mode| {
        var s = try h.Session.init(mode);
        defer s.deinit();
        try seed(&s);
        var f: h.Failures = .{};
        try h.expectRows(&s, &f, "RETURN indegree(-1), outdegree(-1)", &.{"0|0"});
        try h.expectRows(&s, &f, "RETURN indegree(-4611686018427387904), outdegree(-9223372036854775807)", &.{"0|0"});
        try f.finish(@tagName(mode));
    }
}
