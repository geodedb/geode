// SONNY-2686 regression: MERGE matched existing nodes without the session's
// row-level security.
//
// MERGE's match phase (crud_operations.zig `findFirstMatchingNodeId`, reached
// from the node chain, from each relationship endpoint, and from the cluster
// leader) checked the graph, the exact tenant, the labels and the properties,
// and nothing else. So under a label-deny or an expression policy a session
// could:
//   * READ a row it may not see: `MERGE (x:Hidden {s: 'leak'}) RETURN
//     x.secret` bound the hidden node and returned its secret (a bare
//     `MERGE (x:Hidden)` did too);
//   * WRITE it: `ON MATCH SET x.cls = 'public'` (or a bare `SET`) rewrote the
//     hidden row, which under an expression policy reclassifies it as visible;
//   * attach a relationship to it: `MERGE (a)-[:R]->(b:Hidden {s: 'leak'})`
//     bound the hidden node as an endpoint.
//
// The fix applies `passesRowVisibilityFilters` to every node MERGE's match
// phase finds. A visible match binds as before. When the only nodes that match
// are hidden, the statement is REFUSED with `error.MergeMatchNotVisible`
// (42501): nothing is bound, updated or created. Creating a second node would
// break MERGE's one-row-per-key contract (and reveal the hidden row the moment
// the policy lifts); binding it is the leak.
//
// A session no policy restricts (no policy, or no user) is unchanged, and a
// node in another tenant or graph is still simply absent (MERGE creates the
// session's own).
//
// CANARY: REQ=REQ-SONNY-2686-MERGE-ROW-VISIBILITY; FEATURE="MergeRowVisibility"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;

/// The label the fixture's hidden row carries in each mode.
fn hiddenLabel(mode: h.Mode) []const u8 {
    return switch (mode) {
        .expr_policy, .tenant_scoped => "Doc",
        .no_policy, .label_policy => "Hidden",
    };
}

/// One hidden row (`leak`, with a secret) and one visible row (`pub`). The
/// label policy hides `:Hidden`; the expression policy hides `cls = 'secret'`.
fn seed(s: *h.Session) !void {
    const aa = s.arena.allocator();
    const leak = try std.fmt.allocPrint(aa, "CREATE (:{s} {{s: 'leak', cls: 'secret', secret: 's3cr3t'}})", .{hiddenLabel(s.mode)});
    try s.execAs(null, leak);
    try s.execAs(null, "CREATE (:Doc {s: 'pub', cls: 'public'})");
    try s.restrict("Hidden");
}

/// `fmt` with `{L}` replaced by the hidden row's label.
fn q(s: *h.Session, fmt: []const u8) ![]const u8 {
    const aa = s.arena.allocator();
    return std.mem.replaceOwned(u8, aa, fmt, "{L}", hiddenLabel(s.mode));
}

/// The statements that match ONLY the hidden row: every one must be refused.
const refused_statements = [_][]const u8{
    // Node MERGE: read, no-op, ON MATCH, ON CREATE and bare SET.
    "MERGE (x:{L} {s: 'leak'}) RETURN x.secret",
    "MERGE (x:{L} {s: 'leak'})",
    "MERGE (x:{L} {s: 'leak'}) ON MATCH SET x.cls = 'public' RETURN x.s",
    "MERGE (x:{L} {s: 'leak'}) ON CREATE SET x.cls = 'public' RETURN x.s",
    "MERGE (x:{L} {s: 'leak'}) SET x.cls = 'public'",
    // Every match route: two probed index keys, a label scan (no property)
    // and a full scan (no label).
    "MERGE (x:{L} {s: 'leak', cls: 'secret'}) RETURN x.secret",
    "MERGE (x {s: 'leak'}) RETURN x.secret",
    // Relationship MERGE: the hidden node as either endpoint, with ON CREATE,
    // and behind an endpoint a MATCH bound.
    "MERGE (a:Doc {s: 'pub'})-[:R]->(b:{L} {s: 'leak'})",
    "MERGE (a:{L} {s: 'leak'})-[:R]->(b:Doc {s: 'pub'})",
    "MERGE (a:Doc {s: 'pub'})-[r:R]->(b:{L} {s: 'leak'}) ON CREATE SET r.w = 1",
    "MATCH (a:Doc {s: 'pub'}) MERGE (a)-[:R]->(b:{L} {s: 'leak'})",
    // A refusal is atomic: the endpoint (or chain) that comes first and would
    // be created is not left behind.
    "MERGE (a:Doc {s: 'fresh'})-[:R]->(b:{L} {s: 'leak'})",
    "MERGE (n:Doc {s: 'fresh'}) MERGE (x:{L} {s: 'leak'}) RETURN x.secret",
};

fn checkPolicy(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    try seed(&s);
    const aa = s.arena.allocator();
    var f: h.Failures = .{};

    const leak = try s.idOf("leak");
    const pub_id = try s.idOf("pub");

    for (refused_statements) |stmt| try h.expectError(&s, &f, try q(&s, stmt), error.MergeMatchNotVisible);
    if (mode == .label_policy) {
        // A label with no property: only the hidden row carries it.
        try h.expectError(&s, &f, "MERGE (x:Hidden) RETURN x.secret", error.MergeMatchNotVisible);
    } else {
        // Only the hidden row matches the property that hides it.
        try h.expectError(&s, &f, "MERGE (x:Doc {cls: 'secret'}) RETURN x.s", error.MergeMatchNotVisible);
    }
    // A MATCH that binds the hidden endpoint finds no row, so no MERGE runs.
    try h.expectRows(&s, &f, try q(&s, "MATCH (a:Doc {s: 'pub'}), (b:{L} {s: 'leak'}) MERGE (a)-[:R]->(b)"), &.{});

    // Nothing the refused statements touched changed: the hidden row keeps its
    // class and secret, there is still exactly one `leak`, and no edge exists.
    if (!std.mem.eql(u8, h.storedString(leak, "cls") orelse "", "secret")) try f.add(aa, "[{s}] the hidden row was rewritten: cls={s}", .{ @tagName(mode), h.storedString(leak, "cls") orelse "<none>" });
    if (!std.mem.eql(u8, h.storedString(leak, "secret") orelse "", "s3cr3t")) try f.add(aa, "[{s}] the hidden row lost its secret", .{@tagName(mode)});
    if (h.countWithS("leak") != 1) try f.add(aa, "[{s}] {d} nodes named leak (a refused MERGE created one)", .{ @tagName(mode), h.countWithS("leak") });
    if (h.countWithS("fresh") != 0) try f.add(aa, "[{s}] a refused MERGE left {d} node(s) named fresh behind", .{ @tagName(mode), h.countWithS("fresh") });
    if (h.incidentEdges(leak) != 0) try f.add(aa, "[{s}] {d} edge(s) attached to the hidden row", .{ @tagName(mode), h.incidentEdges(leak) });
    if (h.incidentEdges(pub_id) != 0) try f.add(aa, "[{s}] {d} edge(s) attached to pub by a refused MERGE", .{ @tagName(mode), h.incidentEdges(pub_id) });
    try h.expectRows(&s, &f, "MATCH (x) RETURN x.s", &.{"pub"});

    // A match the session may see binds exactly as before, under the policy:
    // ON MATCH on a visible row, ON CREATE on a new key, and a relationship
    // MERGE between visible endpoints (created, then matched).
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'pub'}) ON MATCH SET x.seen = 1 RETURN x.s, x.seen", &.{"pub|1"});
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'new', cls: 'public'}) ON CREATE SET x.fresh = true RETURN x.s, x.fresh", &.{"new|true"});
    try h.expectRows(&s, &f, "MERGE (a:Doc {s: 'pub'})-[r:R]->(b:Doc {s: 'pub2', cls: 'public'}) ON CREATE SET r.w = 1", &.{});
    try h.expectRows(&s, &f, "MATCH (a:Doc {s: 'pub'})-[r:R]->(b) RETURN b.s, r.w", &.{"pub2|1"});
    try h.expectRows(&s, &f, "MERGE (a:Doc {s: 'pub'})-[r:R]->(b:Doc {s: 'pub2'}) ON MATCH SET r.w = 2", &.{});
    try h.expectRows(&s, &f, "MATCH (a:Doc {s: 'pub'})-[r:R]->(b) RETURN b.s, r.w", &.{"pub2|2"});
    // A pattern that matches visible AND hidden rows binds a visible one.
    const any_doc = h.rowsOf(&s, "MERGE (x:Doc) RETURN x.s") catch |err| blk: {
        try f.add(aa, "[{s}] MERGE (x:Doc) RETURN x.s: error {s}", .{ @tagName(mode), @errorName(err) });
        break :blk &.{};
    };
    for (any_doc) |row| {
        if (std.mem.eql(u8, row, "leak")) try f.add(aa, "[{s}] MERGE (x:Doc) bound the hidden row", .{@tagName(mode)});
    }
    if (h.incidentEdges(leak) != 0 or h.countWithS("leak") != 1) try f.add(aa, "[{s}] the hidden row was touched by an allowed MERGE", .{@tagName(mode)});

    try f.finish(@tagName(mode));
}

test "SONNY-2686: under a label-deny policy, a MERGE whose only match is hidden is refused, and never reads, rewrites or attaches to it" {
    try checkPolicy(.label_policy);
}

test "SONNY-2686: under an expression policy, a MERGE whose only match is hidden is refused, and never reads, rewrites or attaches to it" {
    try checkPolicy(.expr_policy);
}

test "SONNY-2686: with no policy, MERGE still matches, updates and attaches to every row (unchanged)" {
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    try seed(&s);
    var f: h.Failures = .{};
    const aa = s.arena.allocator();
    const leak = try s.idOf("leak");

    try h.expectRows(&s, &f, "MERGE (x:Hidden {s: 'leak'}) RETURN x.secret", &.{"s3cr3t"});
    try h.expectRows(&s, &f, "MERGE (x:Hidden) RETURN x.s", &.{"leak"});
    try h.expectRows(&s, &f, "MERGE (x {s: 'leak'}) RETURN x.secret", &.{"s3cr3t"});
    try h.expectRows(&s, &f, "MERGE (x:Hidden {s: 'leak'}) ON MATCH SET x.seen = 1 RETURN x.s, x.seen", &.{"leak|1"});
    try h.expectRows(&s, &f, "MERGE (a:Doc {s: 'pub'})-[:R]->(b:Hidden {s: 'leak'})", &.{});
    try h.expectRows(&s, &f, "MATCH (a:Doc {s: 'pub'})-[:R]->(b) RETURN b.s", &.{"leak"});
    if (h.countWithS("leak") != 1) try f.add(aa, "[no_policy] {d} nodes named leak", .{h.countWithS("leak")});
    if (h.incidentEdges(leak) != 1) try f.add(aa, "[no_policy] expected 1 edge on leak, got {d}", .{h.incidentEdges(leak)});

    // A policy is installed, but a session with no user is not subject to it.
    try s.execAs(null, "CREATE (:Hidden {s: 'anon', secret: 'open'})");
    s.mode = .label_policy;
    try s.restrict("Hidden");
    s.ctx.user = null;
    try h.expectRows(&s, &f, "MERGE (x:Hidden {s: 'anon'}) RETURN x.secret", &.{"open"});

    try f.finish("no_policy");
}

test "SONNY-2686: a node in another tenant or another graph is absent to MERGE, which creates the session's own" {
    var s = try h.Session.init(.tenant_scoped);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};

    try s.execAs(h.tenant_b, "CREATE (:Doc {s: 'leak', cls: 'secret', secret: 's3cr3t'})");
    try s.execAs(h.tenant_a, "CREATE (:Doc {s: 'pub', cls: 'public'})");
    const foreign = try s.idOf("leak");
    const store = graph_store.getGlobalStore(testing.allocator);
    const other_graph = try store.createNodeWithGraph(&[_][]const u8{"Doc"}, "g2");
    try store.setNodeProperty(other_graph, "s", .{ .String = "elsewhere" });
    try store.setNodeProperty(other_graph, "secret", .{ .String = "g2secret" });
    try s.restrict("Hidden");

    // The foreign row is not bound: MERGE creates tenant_a's own `leak`, which
    // the next MERGE then matches (and updates).
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'leak'}) RETURN x.secret", &.{"null"});
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'leak'}) ON MATCH SET x.cls = 'public' RETURN x.cls", &.{"public"});
    try h.expectRows(&s, &f, "MERGE (a:Doc {s: 'pub'})-[:R]->(b:Doc {s: 'leak'})", &.{});
    try h.expectRows(&s, &f, "MATCH (x:Doc {s: 'leak'}) RETURN x.cls", &.{"public"});
    try h.expectRows(&s, &f, "MATCH (a:Doc {s: 'pub'})-[:R]->(b) RETURN b.cls", &.{"public"});
    // Another graph's row is absent too.
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'elsewhere'}) RETURN x.secret", &.{"null"});

    if (!std.mem.eql(u8, h.storedString(foreign, "cls") orelse "", "secret")) try f.add(aa, "[tenant_scoped] the foreign row was rewritten", .{});
    if (h.incidentEdges(foreign) != 0) try f.add(aa, "[tenant_scoped] an edge was attached to the foreign row", .{});
    if (h.countWithS("leak") != 2) try f.add(aa, "[tenant_scoped] expected one leak per tenant, got {d}", .{h.countWithS("leak")});
    if (!std.mem.eql(u8, h.storedString(other_graph, "secret") orelse "", "g2secret")) try f.add(aa, "[tenant_scoped] the other graph's row was touched", .{});

    try f.finish("tenant_scoped");
}

// The QUIC handler's MERGE fast paths (single-node MERGE, the relationship
// MERGE after a MATCH, the /*+BATCH*/ batch, the graph-selector MERGE) and its
// MATCH … CREATE edge fast path find existing nodes by merge key alone, with no
// tenant check and no RLS, so over the wire `MERGE (x:Doc {s: 'leak'}) SET
// x.cls = 'public'` would still rewrite the hidden row. They may serve only a
// session nothing restricts; every other session takes the executor above.
test "SONNY-2686: the key-resolved write fast paths serve only a session no tenant scope or RLS policy restricts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var f: h.Failures = .{};

    for ([_]h.Mode{ .no_policy, .label_policy, .expr_policy, .tenant_scoped }) |mode| {
        var s = try h.Session.init(mode);
        defer s.deinit();
        try s.restrict("Hidden");
        const want = mode == .no_policy;
        const got = geode.bulk_ingest.sessionAllowsKeyResolvedWrites(&s.ctx);
        if (got != want) try f.add(aa, "[{s}] fast paths serve the session: expected {}, got {}", .{ @tagName(mode), want, got });
        if (mode == .label_policy) {
            // An installed policy applies to no session without a user.
            s.ctx.user = null;
            if (!geode.bulk_ingest.sessionAllowsKeyResolvedWrites(&s.ctx)) try f.add(aa, "[label_policy, no user] fast paths declined a session no policy applies to", .{});
            // SONNY-2724: a GPS principal alone is an identity a policy applies
            // to (RLS evaluates under its username).
            const principal_mod = geode.security.principal;
            const principal = principal_mod.Principal{
                .user_id = 2724,
                .username = h.session_user,
                .session_id = null,
                .tenant_id = null,
                .active_graph = null,
                .roles = &.{},
                .custom_roles = &.{},
                .auth_method = .password,
                .auth_version = 1,
                .mfa_state = .none,
                .elevation_until = null,
                .api_key_id = null,
                .certificate_subject = null,
                .risk_context = principal_mod.RiskContext.unknown,
                .attributes = principal_mod.AttributeMap.emptySentinel(),
                .source = .test_harness,
            };
            s.ctx.principal = &principal;
            if (geode.bulk_ingest.sessionAllowsKeyResolvedWrites(&s.ctx)) try f.add(aa, "[label_policy, principal only] fast paths serve a session a policy applies to", .{});
            s.ctx.principal = null;
        }
    }

    // Strict tenancy refuses an unscoped request in the executor; the fast
    // paths must not serve it instead.
    {
        var s = try h.Session.init(.no_policy);
        defer s.deinit();
        geode.tenancy.setStrictTenancy(true);
        defer geode.tenancy.setStrictTenancy(false);
        if (geode.bulk_ingest.sessionAllowsKeyResolvedWrites(&s.ctx)) try f.add(aa, "[strict tenancy, unscoped] fast paths serve the session", .{});
    }

    try f.finish("fast-path gate");
}

// CANARY: REQ=REQ-SONNY-2686-MERGE-EDGE-RLS; FEATURE="MergeRowVisibility"; ASPECT=RelationshipMatchEdgeRls; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-26
/// P12 (the SONNY-2686 security review): a relationship MERGE between two
/// visible nodes matched an existing edge on its graph, tenant and type only
/// (`findExistingEdgeId` / `edgeMatchesScopeAndType`), never on the RLS
/// policies of the edge's type, so `MERGE (a)-[r:SECRET]->(b) ON MATCH SET
/// r.v = 'pwned'` rewrote an edge every MATCH hides (the review's probe turned
/// `orig` into `pwned`). An edge the session may not see now counts like a
/// hidden node: when only hidden edges match, the statement is refused
/// (`MergeMatchNotVisible`), before anything is written.
///
/// Fixture: `pub -SECRET {x: 'topsecret', v: 'orig'}-> pub2`, denied by the
/// label-deny policy on the SECRET type and by the expression policy
/// `x <> 'topsecret'` on it; `pub -R {w: 1}-> pub2`, visible to everyone.
fn checkEdgeMerge(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const open = mode == .no_policy;

    try s.execAs(null, "CREATE (:Doc {s: 'pub', cls: 'public'})");
    try s.execAs(null, "CREATE (:Doc {s: 'pub2', cls: 'public'})");
    try s.execAs(null, "MATCH (a:Doc {s: 'pub'}), (b:Doc {s: 'pub2'}) CREATE (a)-[:SECRET {x: 'topsecret', v: 'orig'}]->(b)");
    try s.execAs(null, "MATCH (a:Doc {s: 'pub'}), (b:Doc {s: 'pub2'}) CREATE (a)-[:R {w: 1}]->(b)");
    const pub_id = try s.idOf("pub");
    const pub2 = try s.idOf("pub2");
    const secret = (try h.edgeIds(aa, pub_id, pub2, "SECRET"))[0];
    const r_edge = (try h.edgeIds(aa, pub_id, pub2, "R"))[0];
    try s.restrict("Hidden");
    try s.restrictEdgeType("SECRET");
    const nodes_before = h.nodeCount();

    // Every statement below matches only the hidden SECRET edge between two
    // visible, existing endpoints.
    const hidden_only = [_][]const u8{
        "MERGE (a:Doc {s: 'pub'})-[r:SECRET]->(b:Doc {s: 'pub2'}) ON MATCH SET r.v = 'pwned'",
        "MERGE (a:Doc {s: 'pub'})-[r:SECRET]->(b:Doc {s: 'pub2'}) ON CREATE SET r.y = 1 ON MATCH SET r.y = 2",
        "MERGE (a:Doc {s: 'pub'})-[r:SECRET]->(b:Doc {s: 'pub2'}) SET r.v = 'pwned'",
        "MERGE (a:Doc {s: 'pub'})-[:SECRET]->(b:Doc {s: 'pub2'})",
        // MATCH-bound endpoints.
        "MATCH (a:Doc {s: 'pub'}), (b:Doc {s: 'pub2'}) MERGE (a)-[r:SECRET]->(b) ON MATCH SET r.v = 'pwned'",
        // An earlier chain that would create a node: the refusal comes first.
        "MERGE (n:Doc {s: 'fresh'}) MERGE (a:Doc {s: 'pub'})-[r:SECRET]->(b:Doc {s: 'pub2'}) ON MATCH SET r.v = 'pwned'",
    };
    if (open) {
        try h.expectRows(&s, &f, hidden_only[0], &.{});
        if (!std.mem.eql(u8, h.storedEdgeString(secret, "v") orelse "", "pwned")) try f.add(aa, "[no_policy] ON MATCH SET did not update the SECRET edge", .{});
    } else {
        for (hidden_only) |stmt| try h.expectError(&s, &f, stmt, error.MergeMatchNotVisible);
        // Read by the owner (unscoped, straight from the store): unchanged.
        const v = h.storedEdgeString(secret, "v") orelse "(none)";
        if (!std.mem.eql(u8, v, "orig")) try f.add(aa, "[{s}] a refused MERGE rewrote the hidden edge: v = {s}", .{ @tagName(mode), v });
        // A refused statement writes nothing at all: no node, no edge, no property.
        if (h.nodeCount() != nodes_before) try f.add(aa, "[{s}] a refused MERGE created {d} node(s)", .{ @tagName(mode), h.nodeCount() -| nodes_before });
        if (h.countWithS("fresh") != 0) try f.add(aa, "[{s}] a refused MERGE left the node its earlier chain created", .{@tagName(mode)});
        if (h.incidentEdges(pub_id) != 2) try f.add(aa, "[{s}] expected pub's 2 edges, got {d} (a refused MERGE created an edge)", .{ @tagName(mode), h.incidentEdges(pub_id) });
        if (h.anyIncidentEdgeHas(pub_id, "y")) try f.add(aa, "[{s}] a refused MERGE set a property on an edge", .{@tagName(mode)});
    }

    // A visible match still updates, and creates nothing.
    try h.expectRows(&s, &f, "MERGE (a:Doc {s: 'pub'})-[r:R]->(b:Doc {s: 'pub2'}) ON MATCH SET r.w = 2", &.{});
    try h.expectRows(&s, &f, "MATCH (a:Doc {s: 'pub'})-[r:R]->(b:Doc {s: 'pub2'}) RETURN r.w", &.{"2"});
    if ((try h.edgeIds(aa, pub_id, pub2, "R")).len != 1) try f.add(aa, "[{s}] the visible edge was duplicated", .{@tagName(mode)});
    _ = r_edge;

    if (mode == .expr_policy) {
        // A visible SECRET edge beside the hidden one: MERGE binds the one the
        // session may see, and the hidden one stays as it was.
        try s.execAs(null, "MATCH (a:Doc {s: 'pub'}), (b:Doc {s: 'pub2'}) CREATE (a)-[:SECRET {x: 'shared', v: 'vis'}]->(b)");
        try h.expectRows(&s, &f, "MERGE (a:Doc {s: 'pub'})-[r:SECRET]->(b:Doc {s: 'pub2'}) ON MATCH SET r.v = 'set'", &.{});
        try h.expectRows(&s, &f, "MATCH (a:Doc {s: 'pub'})-[r:SECRET]->(b) RETURN r.v", &.{"set"});
        const v = h.storedEdgeString(secret, "v") orelse "(none)";
        if (!std.mem.eql(u8, v, "orig")) try f.add(aa, "[expr_policy] MERGE rewrote the hidden edge beside a visible one: v = {s}", .{v});
    }

    try f.finish(@tagName(mode));
}

test "SONNY-2686 (P12): with no policy, a relationship MERGE matches and updates every edge (unchanged)" {
    try checkEdgeMerge(.no_policy);
}

test "SONNY-2686 (P12): under a label-deny policy on an edge type, a relationship MERGE whose only match is a hidden edge is refused and writes nothing" {
    try checkEdgeMerge(.label_policy);
}

test "SONNY-2686 (P12): under an expression policy on an edge's properties, a relationship MERGE whose only match is a hidden edge is refused and writes nothing" {
    try checkEdgeMerge(.expr_policy);
}

// CANARY: REQ=REQ-SONNY-2728-MERGE-REFUSAL-AUDIT; FEATURE="MergeRowVisibility"; ASPECT=RefusalAudit; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-26
// SONNY-2728: a MergeMatchNotVisible refusal tells the session that some row
// it may not see equals the MERGE pattern, so it works as an equality oracle
// over any property value (the SONNY-2686 review's probe P14: guessing
// `salary: 250000` is refused, a wrong guess creates a node). It stays (see
// docs/kb/RLS_IMPLEMENTATION.md for why binding or hiding the row is worse),
// and every refusal is audited: the user, the graph, the labels or
// relationship types and the property KEYS, never the values, which are the
// secret being guessed. An allowed MERGE is not audited as a refusal.
test "SONNY-2728: every MERGE refused for a hidden match is audited with the user, graph, labels and keys, never the values" {
    var s = try h.Session.init(.label_policy);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const audit = geode.security.audit;

    try s.execAs(null, "CREATE (:Hidden {s: 'leak', salary: 250000})");
    try s.execAs(null, "CREATE (:Doc {s: 'pub', cls: 'public'})");
    try s.execAs(null, "CREATE (:Doc {s: 'pub2', cls: 'public'})");
    try s.execAs(null, "MATCH (a:Doc {s: 'pub'}), (b:Doc {s: 'pub2'}) CREATE (a)-[:SECRET {x: 'topsecret'}]->(b)");
    try s.restrict("Hidden");
    try s.restrictEdgeType("SECRET");

    const sink_path = try std.fmt.allocPrint(aa, "{s}/audit.jsonl", .{s.data_dir});
    const logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = sink_path });
    defer {
        audit.setGlobalAuditLogger(null);
        logger.deinit();
        testing.allocator.destroy(logger);
    }
    audit.setGlobalAuditLogger(logger);

    // Two refusals: a node guess (the probe's equality oracle) and an edge.
    try h.expectError(&s, &f, "MERGE (x:Hidden {s: 'leak', salary: 250000}) RETURN x.s", error.MergeMatchNotVisible);
    try h.expectError(&s, &f, "MERGE (a:Doc {s: 'pub'})-[r:SECRET {tag: 'kval9'}]->(b:Doc {s: 'pub2'})", error.MergeMatchNotVisible);
    // Not refusals: a wrong guess creates its node, a visible row is bound.
    try h.expectRows(&s, &f, "MERGE (x:Hidden {s: 'leak', salary: 1}) RETURN x.salary", &.{"1"});
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'pub'}) RETURN x.s", &.{"pub"});

    const io = std.Io.Threaded.global_single_threaded.io();
    const sink = std.Io.Dir.cwd().readFileAlloc(io, sink_path, aa, .limited(1 << 20)) catch |err| blk: {
        try f.add(aa, "audit sink unreadable: {s}", .{@errorName(err)});
        break :blk "";
    };
    // The refusal records alone (one JSON line each).
    var records: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, sink, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "MERGE_MATCH_NOT_VISIBLE") != null) try records.append(aa, line);
    }
    if (records.items.len != 2) try f.add(aa, "expected 2 MERGE_MATCH_NOT_VISIBLE audit records, found {d}", .{records.items.len});
    const all = try std.mem.join(aa, "\n", records.items);
    for ([_][]const u8{ h.session_user, "access_denied", "failure", "graph=default", "labels=[Hidden]", "keys=[s,salary]", "labels=[SECRET]", "keys=[tag]" }) |want| {
        if (std.mem.indexOf(u8, all, want) == null) try f.add(aa, "the refusal records lack `{s}`", .{want});
    }
    // Never a value from the patterns.
    for ([_][]const u8{ "leak", "250000", "kval9", "pub2" }) |secret| {
        if (std.mem.indexOf(u8, all, secret) != null) try f.add(aa, "a refusal record carries the value `{s}`", .{secret});
    }

    try f.finish("SONNY-2728 audit");
}
