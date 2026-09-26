// SONNY-2692 regression: knn() / vector_knn() ignored row-level security.
//
// Both vector paths scoped their candidates by graph and tenant only
// (eval.zig `KnnScanScope.admits`, and the index path's authority check), so
// under a label-deny or an expression policy knn() returned the ids of rows the
// session may not see, ranked by their distance to a vector the caller chose:
// a similarity oracle over denied data.
//
// The fix applies the row-visibility filter (`passesRowVisibilityFilters`) to
// every candidate, on the brute-force scan path and on the vector-index path,
// BEFORE the candidates are ranked and cut to k, so a hidden row can never take
// one of the k slots (the index path over-fetches until it has k visible rows
// or the index runs out). A hidden row does not make its property "known"
// either: a property only hidden rows carry is as unknown to the session as a
// misspelled one (error.UnknownProperty), so the diagnostic is no oracle.
//
// An edge's vector is a knn() candidate too: under a policy it counts only where
// a traversal could return the edge, between two nodes the session may see
// (SONNY-2679).
//
// The control session (no policy) is unchanged on both paths.
//
// CANARY: REQ=REQ-SONNY-2692-KNN-ROW-VISIBILITY; FEATURE="VectorKnn"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2692_knn_rls.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const eval = geode.eval;

/// `[a,b,...]` for the ids, in rank order.
fn idList(aa: std.mem.Allocator, ids: []const u64) ![]const u8 {
    var parts = try aa.alloc([]const u8, ids.len);
    for (ids, 0..) |id, i| parts[i] = try std.fmt.allocPrint(aa, "{d}", .{id});
    return std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ",", parts)});
}

/// The id of the `label` edge from `from` to `to` (read straight from the store).
fn edgeId(from: u64, to: u64, label: []const u8) !u64 {
    const store = geode.graph_store.getGlobalStore(testing.allocator);
    const ids = store.getOutgoingEdgeIds(from) orelse return error.EdgeNotFound;
    for (ids) |eid| {
        const e = store.getEdgeHydrated(eid) orelse continue;
        if (e.to_id == to and std.mem.eql(u8, e.label, label)) return eid;
    }
    return error.EdgeNotFound;
}

/// The label the hidden rows carry in each mode (the label policy hides it).
fn hiddenLabel(mode: h.Mode) []const u8 {
    return if (mode == .expr_policy) "Doc" else "Hidden";
}

/// Brute-force scan path: `vok` is visible, `vleak` is hidden and is the
/// NEAREST row to the query vector [0, 1], and `only` (hidden) is the one row
/// that carries `emb2`. No vector index exists, so every knn() here scans.
fn checkScan(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const open = mode == .no_policy;
    const hid = hiddenLabel(mode);

    try s.execAs(null, "CREATE (:Doc {s: 'vok', cls: 'public', emb: vectorf32([1.0, 0.0])})");
    try s.execAs(null, try std.fmt.allocPrint(aa, "CREATE (:{s} {{s: 'vleak', cls: 'secret', emb: vectorf32([0.0, 1.0])}})", .{hid}));
    try s.execAs(null, try std.fmt.allocPrint(aa, "CREATE (:{s} {{s: 'only', cls: 'secret', emb2: vectorf32([1.0, 1.0])}})", .{hid}));
    const vok = try s.idOf("vok");
    const vleak = try s.idOf("vleak");
    const only = try s.idOf("only");
    try s.restrict("Hidden");

    const ranked_open = [_]u64{ vleak, vok };
    const ranked_hidden = [_]u64{vok};
    const all = try idList(aa, if (open) &ranked_open else &ranked_hidden);
    const top1 = try idList(aa, if (open) ranked_open[0..1] else ranked_hidden[0..1]);

    eval.resetKnnScanInvocations();
    try h.expectRows(&s, &f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{all});
    try h.expectRows(&s, &f, "RETURN vector_knn('emb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{all});
    // k = 1: the hidden row is the nearest, and must not take the only slot.
    try h.expectRows(&s, &f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 1, 'l2') AS ids", &.{top1});
    try h.expectRows(&s, &f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 1, 'cosine') AS ids", &.{top1});
    if (eval.knnScanInvocationCount() == 0) try f.add(aa, "[{s}] the scan path never ran", .{@tagName(mode)});

    // A property only hidden rows carry is unknown to the session.
    if (open) {
        const only_ids = [_]u64{only};
        try h.expectRows(&s, &f, "RETURN knn('emb2', vectorf32([1.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, &only_ids)});
    } else {
        try h.expectError(&s, &f, "RETURN knn('emb2', vectorf32([1.0, 1.0]), 5, 'l2') AS ids", error.UnknownProperty);
    }

    try f.finish(@tagName(mode));
}

/// Edge vectors, on the scan path: `vok -E-> vok2` joins two visible nodes,
/// `vok -E-> vleak` (the nearer to [0, 1]) and `vok -F-> vleak` (the only
/// carrier of `eonly`) end at the hidden node.
fn checkEdges(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const open = mode == .no_policy;
    const hid = hiddenLabel(mode);

    try s.execAs(null, "CREATE (:Doc {s: 'vok', cls: 'public'})");
    try s.execAs(null, "CREATE (:Doc {s: 'vok2', cls: 'public'})");
    try s.execAs(null, try std.fmt.allocPrint(aa, "CREATE (:{s} {{s: 'vleak', cls: 'secret'}})", .{hid}));
    try s.execAs(null, "MATCH (a:Doc {s: 'vok'}), (b:Doc {s: 'vok2'}) CREATE (a)-[:E {eemb: vectorf32([1.0, 0.0])}]->(b)");
    try s.execAs(null, try std.fmt.allocPrint(aa, "MATCH (a:Doc {{s: 'vok'}}), (b:{s} {{s: 'vleak'}}) CREATE (a)-[:E {{eemb: vectorf32([0.0, 1.0])}}]->(b)", .{hid}));
    try s.execAs(null, try std.fmt.allocPrint(aa, "MATCH (a:Doc {{s: 'vok'}}), (b:{s} {{s: 'vleak'}}) CREATE (a)-[:F {{eonly: vectorf32([1.0, 1.0])}}]->(b)", .{hid}));
    const vok = try s.idOf("vok");
    const vok2 = try s.idOf("vok2");
    const vleak = try s.idOf("vleak");
    const e_ok = try edgeId(vok, vok2, "E");
    const e_hidden = try edgeId(vok, vleak, "E");
    const f_hidden = try edgeId(vok, vleak, "F");
    try s.restrict("Hidden");

    const ranked_open = [_]u64{ e_hidden, e_ok };
    const ranked_hidden = [_]u64{e_ok};
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, if (open) &ranked_open else &ranked_hidden)});
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 1, 'l2') AS ids", &.{try idList(aa, if (open) ranked_open[0..1] else ranked_hidden[0..1])});
    if (open) {
        const f_ids = [_]u64{f_hidden};
        try h.expectRows(&s, &f, "RETURN knn('eonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, &f_ids)});
    } else {
        try h.expectError(&s, &f, "RETURN knn('eonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids", error.UnknownProperty);
    }

    try f.finish(@tagName(mode));
}

/// Vector-index path: every carrier of `emb` is a `:Doc`, and the index on
/// `:Doc(emb)` answers (the scan never runs). Under the expression policy
/// `vleak` is hidden and nearest to [0, 1]; under the label policy, which here
/// denies `:Doc`, every row the index holds is hidden.
fn checkIndex(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};

    try s.execAs(null, "CREATE (:Doc {s: 'vok', cls: 'public', emb: vectorf32([1.0, 0.0])})");
    try s.execAs(null, "CREATE (:Doc {s: 'vleak', cls: 'secret', emb: vectorf32([0.0, 1.0])})");
    try s.execAs(null, "CREATE (:Doc {s: 'vfar', cls: 'public', emb: vectorf32([-1.0, -0.5])})");
    try s.execAs(null, "CREATE INDEX doc_emb ON Doc (emb) USING vector");
    const vok = try s.idOf("vok");
    const vleak = try s.idOf("vleak");
    const vfar = try s.idOf("vfar");
    try s.restrict("Doc");

    // Ranked by distance to [0, 1]: vleak 0, vok 1.41, vfar 1.80.
    const ranked_open = [_]u64{ vleak, vok, vfar };
    const ranked_expr = [_]u64{ vok, vfar };
    const all: []const u64 = switch (mode) {
        .no_policy => &ranked_open,
        .expr_policy => &ranked_expr,
        else => &.{},
    };
    const top1 = all[0..@min(1, all.len)];

    eval.resetKnnScanInvocations();
    try h.expectRows(&s, &f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, all)});
    try h.expectRows(&s, &f, "RETURN vector_knn('emb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, all)});
    // k = 1 and k = 2: the index's own top-k starts with the hidden row, and
    // the session must still get k visible rows.
    try h.expectRows(&s, &f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 1, 'l2') AS ids", &.{try idList(aa, top1)});
    try h.expectRows(&s, &f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 2, 'l2') AS ids", &.{try idList(aa, all[0..@min(2, all.len)])});
    if (eval.knnScanInvocationCount() != 0) try f.add(aa, "[{s}] the scan ran {d} time(s): the index path was not exercised", .{ @tagName(mode), eval.knnScanInvocationCount() });

    try f.finish(@tagName(mode));
}

test "SONNY-2692: scan path, no policy: knn() ranks every row (unchanged)" {
    try checkScan(.no_policy);
}

test "SONNY-2692: scan path, label-deny policy: a hidden row is never a knn() candidate" {
    try checkScan(.label_policy);
}

test "SONNY-2692: scan path, expression policy: a hidden row is never a knn() candidate" {
    try checkScan(.expr_policy);
}

test "SONNY-2692: index path, no policy: the vector index ranks every row (unchanged)" {
    try checkIndex(.no_policy);
}

test "SONNY-2692: index path, label-deny policy: no hidden row comes back from the vector index" {
    try checkIndex(.label_policy);
}

test "SONNY-2692: index path, expression policy: a hidden row never takes one of the k slots" {
    try checkIndex(.expr_policy);
}

test "SONNY-2692: edge vectors, no policy: every edge is ranked (unchanged)" {
    try checkEdges(.no_policy);
}

test "SONNY-2692: edge vectors, label-deny policy: an edge to a hidden node is never a knn() candidate" {
    try checkEdges(.label_policy);
}

test "SONNY-2692: edge vectors, expression policy: an edge to a hidden node is never a knn() candidate" {
    try checkEdges(.expr_policy);
}

// CANARY: REQ=REQ-SONNY-2692-KNN-EDGE-RLS; FEATURE="VectorKnn"; ASPECT=EdgeCandidateRls; STATUS=TESTED; TEST=tests/test_sonny2692_knn_rls.zig; OWNER=security; UPDATED=2026-09-26
/// P13 (the SONNY-2686 security review): an edge's vector was a knn()
/// candidate whenever both its endpoints were visible; the RLS policies of the
/// edge's own type were never applied, so knn() ranked, and returned the id
/// of, an edge every MATCH hides (the review's probe ranked the denied SECRET
/// edge first). Every edge candidate now passes `HopScope.edgeVisible` (its
/// graph, its tenant tag and the RLS policies on its type) before it is
/// ranked, and before it can make the property "known".
///
/// Fixture, all between two visible `:Doc` nodes: `vok -SECRET {eemb: [0, 1],
/// x: 'topsecret', sonly: [1, 1]}-> vok2` (denied by the label policy on the
/// SECRET type and by the expression policy `x <> 'topsecret'`), and two
/// visible `:E` edges, `[0.6, 0.8]` and `[1, 0]`. Ranked by distance to
/// [0, 1]: SECRET 0, the first E 0.63, the second E 1.41.
fn checkEdgeRls(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const open = mode == .no_policy;

    try s.execAs(null, "CREATE (:Doc {s: 'vok', cls: 'public'})");
    try s.execAs(null, "CREATE (:Doc {s: 'vok2', cls: 'public'})");
    try s.execAs(null, "MATCH (a:Doc {s: 'vok'}), (b:Doc {s: 'vok2'}) CREATE (a)-[:SECRET {x: 'topsecret', eemb: vectorf32([0.0, 1.0]), sonly: vectorf32([1.0, 1.0])}]->(b)");
    try s.execAs(null, "MATCH (a:Doc {s: 'vok'}), (b:Doc {s: 'vok2'}) CREATE (a)-[:E {eemb: vectorf32([0.6, 0.8])}]->(b)");
    try s.execAs(null, "MATCH (a:Doc {s: 'vok'}), (b:Doc {s: 'vok2'}) CREATE (a)-[:F {eemb: vectorf32([1.0, 0.0])}]->(b)");
    const vok = try s.idOf("vok");
    const vok2 = try s.idOf("vok2");
    const secret = try edgeId(vok, vok2, "SECRET");
    const near = try edgeId(vok, vok2, "E");
    const far = try edgeId(vok, vok2, "F");
    try s.restrict("Hidden");
    try s.restrictEdgeType("SECRET");

    const ranked_open = [_]u64{ secret, near, far };
    const ranked_hidden = [_]u64{ near, far };
    const all: []const u64 = if (open) &ranked_open else &ranked_hidden;
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, all)});
    try h.expectRows(&s, &f, "RETURN vector_knn('eemb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, all)});
    // k = 1: the denied edge is the nearest, and must not take the only slot.
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 1, 'l2') AS ids", &.{try idList(aa, all[0..1])});
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 2, 'cosine') AS ids", &.{try idList(aa, all[0..2])});
    // A property only the denied edge carries is unknown to the session.
    if (open) {
        const only = [_]u64{secret};
        try h.expectRows(&s, &f, "RETURN knn('sonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, &only)});
    } else {
        try h.expectError(&s, &f, "RETURN knn('sonly', vectorf32([1.0, 1.0]), 5, 'l2') AS ids", error.UnknownProperty);
    }

    try f.finish(@tagName(mode));
}

test "SONNY-2692 (P13): edge vectors, no policy: an edge of every type is ranked (unchanged)" {
    try checkEdgeRls(.no_policy);
}

test "SONNY-2692 (P13): edge vectors, label-deny policy on the edge type: a denied edge is never a knn() candidate" {
    try checkEdgeRls(.label_policy);
}

test "SONNY-2692 (P13): edge vectors, expression policy on the edge's properties: a denied edge is never a knn() candidate" {
    try checkEdgeRls(.expr_policy);
}

// CANARY: REQ=REQ-SONNY-2692-KNN-EDGE-TENANT-RULE; FEATURE="VectorKnn"; ASPECT=EdgeCandidateEndpoints; STATUS=TESTED; TEST=tests/test_sonny2692_knn_rls.zig; OWNER=security; UPDATED=2026-09-26
// The single edge-tenant rule (SONNY-2693) on knn(): an edge's vector is a
// candidate for a tenant only when its own tag AND both its endpoints are
// visible to the tenant. The edge scan checked the endpoints only under an RLS
// policy, so a tenant-scoped session ranked, and got the id of, an edge
// tagged with its own tenant that ends at another tenant's node.
test "SONNY-2692 (P13): edge vectors, tenant scope: an edge to another tenant's node is never a knn() candidate" {
    var s = try h.Session.init(.tenant_scoped);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};

    try s.execAs(h.tenant_a, "CREATE (:Doc {s: 'vok', cls: 'public'})");
    try s.execAs(h.tenant_a, "CREATE (:Doc {s: 'vok2', cls: 'public'})");
    try s.execAs(h.tenant_b, "CREATE (:Doc {s: 'vfar', cls: 'public'})");
    try s.execAs(h.tenant_a, "MATCH (a:Doc {s: 'vok'}), (b:Doc {s: 'vok2'}) CREATE (a)-[:E {eemb: vectorf32([1.0, 0.0])}]->(b)");
    const vok = try s.idOf("vok");
    const vok2 = try s.idOf("vok2");
    const vfar = try s.idOf("vfar");
    // tenant_a's own tag, ending at tenant_b's node (the SONNY-2693 "own
    // cross" shape): the nearest to [0, 1].
    const store = geode.graph_store.getGlobalStore(testing.allocator);
    const bridge = try store.createEdgeWithGraphAndTenant(vok, vfar, "E", geode.graph_store.DEFAULT_GRAPH_NAME, h.tenant_a);
    try s.execAs(null, "MATCH (a:Doc {s: 'vok'})-[r:E]->(b:Doc {s: 'vfar'}) SET r.eemb = vectorf32([0.0, 1.0])");
    const inside = try edgeId(vok, vok2, "E");
    try s.restrict("Hidden");

    const ranked = [_]u64{inside};
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", &.{try idList(aa, &ranked)});
    try h.expectRows(&s, &f, "RETURN knn('eemb', vectorf32([0.0, 1.0]), 1, 'l2') AS ids", &.{try idList(aa, &ranked)});
    _ = bridge;

    try f.finish("tenant_scoped");
}
