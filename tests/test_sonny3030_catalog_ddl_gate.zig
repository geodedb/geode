// SONNY-3030 regression: index and constraint DDL need the schema permission
// on the database.
//
// SONNY-2803 gated graph, index and constraint DDL on the schema permission
// for the graph the statement runs on. Indexes and constraints are
// catalogued database-wide, by label, and bind every graph. So a user with a
// `FOR SCHEMA` grant on one graph (a tenant admin of g2) changed what every
// other graph enforces (review probe probe_2803_catalog_scope): a UNIQUE or
// NOT NULL constraint created from g2 refused writes on g1 and default, and
// the user dropped an index an Admin created from g1.
//
// Now CREATE/DROP INDEX (fulltext included) and CREATE/DROP CONSTRAINT need,
// besides SONNY-2803's gate, `decide(schema)` on the whole database: Admin's
// builtin Schema permission, or a GPS policy `FOR SCHEMA` scoped to `*`.
//
// CANARY: REQ=REQ-SONNY-3030-CATALOG-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3030_catalog_ddl_gate.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;

fn indexExists(name: []const u8) !bool {
    const cat = try geode.execution.ensureCatalogInstance(testing.allocator);
    var it = cat.indexes.valueIterator();
    while (it.next()) |info| {
        if (std.mem.eql(u8, info.name, name)) return true;
    }
    return false;
}

/// Authorization on, graphs g1 and g2, an Admin and a ReadWrite session, and
/// `FOR SCHEMA` allow policies on g2 and default (a tenant admin of those
/// graphs), not on `*`.
const Fixture = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    st: *graph_store.GraphStore,
    cat: policy_catalog.PolicyCatalog,
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,
    admin: []const u8 = "",
    rw: []const u8 = "",

    fn init(self: *Fixture) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        self.st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try self.st.createGraph("g1");
        try self.st.createGraph("g2");
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("cat_admin", "", .Admin, null, null, false, 0);
        self.rw = try self.sessions.createSession("cat_rw", "", .ReadWrite, null, null, false, 0);

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        const schema_action = [_]policy_catalog.Action{.schema};
        try self.cat.addPolicy(.{ .name = "schema_g2_3030", .scope_graph = "g2", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });
        try self.cat.addPolicy(.{ .name = "schema_default_3030", .scope_graph = "default", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });
        policy_catalog.setGlobalCatalog(&self.cat);
    }

    fn deinit(self: *Fixture) void {
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }
};

test "SONNY-3030: a FOR SCHEMA grant on some graphs does not reach the database-wide catalog: no constraint or index DDL, and an Admin's index stays (probe_2803_catalog_scope)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.arena.allocator();

    // A: a UNIQUE and a NOT NULL constraint from g2 would bind g1 and default.
    _ = try fx.expectRefused(ga, f.rw, "USE GRAPH g2; CREATE CONSTRAINT probe_u FOR (n:Acct) REQUIRE n.code IS UNIQUE", "42501");
    try fx.expectRuns(ga, f.rw, "USE GRAPH default");
    _ = try fx.expectRefused(ga, f.rw, "USE GRAPH g2; CREATE CONSTRAINT probe_nn FOR (n:Invoice) REQUIRE n.num IS NOT NULL", "42501");
    try fx.expectRuns(ga, f.rw, "USE GRAPH default");
    try fx.expectRuns(ga, f.admin, "USE GRAPH g1; CREATE (:Acct {code: 'x1'})");
    try fx.expectRuns(ga, f.admin, "USE GRAPH g1; CREATE (:Acct {code: 'x1'})");
    try fx.expectRuns(ga, f.admin, "USE GRAPH g1; CREATE (:Invoice {qty: 1})");
    try fx.expectRuns(ga, f.admin, "USE GRAPH default");

    // B: the Admin's index from g1 is not the grant holder's to drop, nor may
    // it create one (a fulltext one included) or drop a constraint.
    try fx.expectRuns(ga, f.admin, "USE GRAPH g1; CREATE INDEX probe_idx_g1 FOR (n:Item) ON (n.k)");
    try fx.expectRuns(ga, f.admin, "USE GRAPH default");
    try testing.expect(try indexExists("probe_idx_g1"));
    _ = try fx.expectRefused(ga, f.rw, "DROP INDEX probe_idx_g1", "42501");
    try testing.expect(try indexExists("probe_idx_g1"));
    _ = try fx.expectRefused(ga, f.rw, "CREATE INDEX probe_idx_rw FOR (n:Item) ON (n.j)", "42501");
    _ = try fx.expectRefused(ga, f.rw, "CREATE INDEX probe_fts_rw FOR (n:Doc) ON (n.body) USING fulltext", "42501");
    _ = try fx.expectRefused(ga, f.rw, "DROP CONSTRAINT probe_u", "42501");
    try testing.expect(!try indexExists("probe_idx_rw"));

    // The Admin may.
    try fx.expectRuns(ga, f.admin, "DROP INDEX probe_idx_g1");
    try testing.expect(!try indexExists("probe_idx_g1"));
}

test "SONNY-3030: a FOR SCHEMA policy scoped to * is the database-level grant" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.arena.allocator();
    const schema_action = [_]policy_catalog.Action{.schema};
    try f.cat.addPolicy(.{ .name = "schema_all_3030", .scope_graph = "*", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });

    try fx.expectRuns(ga, f.rw, "USE GRAPH g2; CREATE INDEX probe_idx_all FOR (n:Item) ON (n.k)");
    try fx.expectRuns(ga, f.rw, "USE GRAPH default");
    try testing.expect(try indexExists("probe_idx_all"));
    try fx.expectRuns(ga, f.rw, "DROP INDEX probe_idx_all");
    try testing.expect(!try indexExists("probe_idx_all"));
}
