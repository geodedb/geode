// Per-graph grants for every role (REQ-SEC-PER-GRAPH-GRANTS, 2026-10).
//
// `GRANT READ|WRITE|SCHEMA ON GRAPH g TO u` gives `u` that privilege on `g`
// and nowhere else, at once, and `REVOKE` takes it away at once, whatever
// `u`'s built-in role. A built-in role's permission still holds on every
// graph.
//
// Before the fix, for a user with an explicit role:
//   - gps.decide read grants only through the Policy rows grant_migration
//     wrote at startup, so a runtime GRANT did nothing until a restart;
//   - the row was scoped to the grant's graph, but the handlers' write gate
//     asked for write on the whole database, which any graph-scoped allow
//     policy matched: after the restart a WRITE grant on g1 allowed writes on
//     every graph;
//   - REVOKE removed the grant but never the row, so a grant a restart had
//     migrated could not be revoked at all.
//
// The grant table here is a real `GraphRBACPolicy`, the one GRANT and REVOKE
// update (`server_init.grantApply` / `grantRevoke`), served to gps through
// `execution.graph_grant_check_fn` the way `server_init.graphGrantCheck`
// serves it. The gRPC tests run real programs through the in-process gRPC
// Execute handler.
//
// CANARY: REQ=REQ-SEC-PER-GRAPH-GRANTS; FEATURE="PerGraphGrants"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_per_graph_grants.zig; OWNER=security; UPDATED=2026-10-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");
const grant_migration = @import("grant_migration");

const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;
const decision_cache = geode.security.decision_cache;
const session_graph = geode.execution.session_graph;
const mgs = geode.multi_graph_security;
const user_mgmt = geode.user_management;
const graph_store = geode.graph_store;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const Role = user_mgmt.Role;

const READ: u8 = 0;
const WRITE: u8 = 1;
const SCHEMA: u8 = 2;

// ---------------------------------------------------------------------------
// The live grant table
// ---------------------------------------------------------------------------

/// User ids for the in-process tests (the restart tests use the
/// AuthGraphManager's).
const users = [_]struct { name: []const u8, id: u64 }{
    .{ .name = "otto", .id = 11 }, // readonly
    .{ .name = "rita", .id = 12 }, // readwrite
    .{ .name = "uma", .id = 13 }, // user
    .{ .name = "ada", .id = 14 }, // admin
};

fn userId(name: []const u8) ?u64 {
    for (users) |u| if (std.mem.eql(u8, u.name, name)) return u.id;
    return null;
}

/// `server_init.graphGrantCheck` with a fixed user table.
fn liveGrantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    const uid = userId(username) orelse return false;
    const pol = mgs.getGlobalPolicy() orelse return false;
    return pol.hasGraphGrant(uid, graph_name, action);
}

/// `server_init.graphGrantCheck`: user ids from the global AuthGraphManager.
fn agmGrantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    const agm = AuthGraphManager.getGlobal() orelse return false;
    const uid = (agm.findUserIdByName(username) catch null) orelse return false;
    const pol = mgs.getGlobalPolicy() orelse return false;
    return pol.hasGraphGrant(uid, graph_name, action);
}

fn grant(pol: *mgs.GraphRBACPolicy, user: []const u8, graph: []const u8, action: u8) !void {
    try pol.grantGraphPermission(userId(user).?, graph, action);
}

fn revoke(pol: *mgs.GraphRBACPolicy, user: []const u8, graph: []const u8, action: u8) void {
    _ = pol.revokeGraphPermission(userId(user).?, graph, action);
}

fn testPrincipal(username: []const u8, roles: []const []const u8, auth_version: u64) principal_mod.Principal {
    return .{
        .user_id = null,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = auth_version,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

fn decideKind(p: *const principal_mod.Principal, action: gps.Action, resource: gps.ResourceRef) !gps.PolicyDecisionKind {
    const req = gps.DecisionRequest{ .principal = p, .action = action, .resource = resource };
    return (try gps.decide(testing.allocator, &req)).kind;
}

// ---------------------------------------------------------------------------
// gRPC plumbing (as tests/test_default_role_fail_closed.zig)
// ---------------------------------------------------------------------------

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

/// `query` through the real gRPC Execute handler. Null when it ran; the
/// SQLSTATE when it was refused.
fn grpcOutcome(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !?[]const u8 {
    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = query,
        .params = .empty,
    });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e.code,
        else => null,
    };
}

fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    if (try grpcOutcome(ga, session_id, query)) |code| {
        std.debug.print("expected `{s}` to run, refused with {s}\n", .{ query, code });
        return error.ExpectedToRun;
    }
}

fn expectDenied(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const code = (try grpcOutcome(ga, session_id, query)) orelse {
        std.debug.print("expected `{s}` to be refused (42501), it ran\n", .{query});
        return error.ExpectedRefusal;
    };
    try testing.expectEqualStrings("42501", code);
}

fn countIn(graph: []const u8, label: []const u8) usize {
    const st = graph_store.getGlobalStore(testing.allocator);
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

/// An in-process deployment with auth on, graphs `default`, `g1` and `g2`,
/// an empty live grant table, and an empty policy catalog.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    pol: mgs.GraphRBACPolicy,
    cat: PolicyCatalog,
    auth_was_enabled: bool,
    prev_grant_fn: ?*const fn ([]const u8, []const u8, u8) bool,
    prev_pol: ?*mgs.GraphRBACPolicy,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        try self.h.seed(&.{"CREATE (:Seed {v: 1})"});
        const st = graph_store.getGlobalStore(testing.allocator);
        for ([_][]const u8{ "g1", "g2" }) |g| {
            _ = try st.createGraph(g);
            _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, g);
        }

        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        self.prev_pol = mgs.getGlobalPolicy();
        mgs.setGlobalPolicy(&self.pol);
        self.prev_grant_fn = geode.execution.graph_grant_check_fn;
        geode.execution.graph_grant_check_fn = &liveGrantCheck;
        self.cat = PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        geode.execution.graph_grant_check_fn = self.prev_grant_fn;
        mgs.setGlobalPolicy(self.prev_pol);
        self.pol.deinit();
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        self.h.deinit();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn session(self: *World, username: []const u8, role: Role, graph: ?[]const u8) ![]const u8 {
        return self.sessions.createSession(username, "", role, null, graph, false, 0);
    }
};

// ---------------------------------------------------------------------------
// WRITE
// ---------------------------------------------------------------------------

test "gRPC: GRANT WRITE ON GRAPH g1 lets a readonly user write g1 at once and not g2; REVOKE stops it at once" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    // READ on both graphs, so otto can bind them (USE GRAPH), as a
    // readonly user must.
    try grant(&w.pol, "otto", "g1", READ);
    try grant(&w.pol, "otto", "g2", READ);
    const s = try w.session("otto", .ReadOnly, null);

    try expectDenied(ga, s, "USE GRAPH g1; CREATE (:W {v: 0})");

    // The runtime GRANT: no restart.
    try grant(&w.pol, "otto", "g1", WRITE);
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:W {v: 1})");
    try testing.expectEqual(@as(usize, 1), countIn("g1", "W"));
    // Scoped to g1: not g2, not the default graph.
    try expectDenied(ga, s, "USE GRAPH g2; CREATE (:W {v: 2})");
    const s0 = try w.session("otto", .ReadOnly, null);
    try expectDenied(ga, s0, "CREATE (:W {v: 3})");
    try testing.expectEqual(@as(usize, 0), countIn("g2", "W"));
    try testing.expectEqual(@as(usize, 0), countIn(graph_store.DEFAULT_GRAPH_NAME, "W"));
    // A session that starts on g2 cannot write it either.
    const s2 = try w.session("otto", .ReadOnly, "g2");
    try expectDenied(ga, s2, "CREATE (:W {v: 4})");
    try testing.expectEqual(@as(usize, 0), countIn("g2", "W"));

    // The runtime REVOKE: no restart.
    revoke(&w.pol, "otto", "g1", WRITE);
    try expectDenied(ga, s, "USE GRAPH g1; CREATE (:W {v: 5})");
    try testing.expectEqual(@as(usize, 1), countIn("g1", "W"));
    // Reading g1 is the readonly role's own, and stays.
    try expectRuns(ga, s, "USE GRAPH g1; MATCH (n:W) RETURN count(n) AS c");
}

test "gps: a write grant counts only on its graph, at once, for every role without global write" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ro = testPrincipal("otto", &.{"ReadOnly"}, 0);
    const user = testPrincipal("uma", &.{"User"}, 0);
    for ([_]*const principal_mod.Principal{ &ro, &user }) |p| {
        const name = p.username.?;
        try testing.expect(!gps.writePermittedOn(testing.allocator, p, "g1"));
        try grant(&w.pol, name, "g1", WRITE);
        try testing.expect(gps.writePermittedOn(testing.allocator, p, "g1"));
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(p, .create, .{ .graph = "g1" }));
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(p, .write, .{ .node = .{ .graph = "g1", .id = 1 } }));
        try testing.expect(!gps.writePermittedOn(testing.allocator, p, "g2"));
        // Not database-wide, and not every graph at once.
        try testing.expect(!gps.writePermitted(testing.allocator, p));
        try testing.expect(try decideKind(p, .write, .{ .graph = "*" }) != .allow);
        try testing.expect(try decideKind(p, .write, .{ .procedure = "geode.tenant.backfill_edge_tags" }) != .allow);
        // No other privilege from it.
        try testing.expect(!session_graph.maySchema(p, "g1"));
        revoke(&w.pol, name, "g1", WRITE);
        try testing.expect(!gps.writePermittedOn(testing.allocator, p, "g1"));
    }
}

test "gps: with the decision cache on, a GRANT and a REVOKE each take effect at once" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var cache = decision_cache.DecisionCache.init(testing.allocator, decision_cache.DEFAULT_CAPACITY);
    defer cache.deinit();
    const prev_cache = decision_cache.getGlobalCache();
    decision_cache.setGlobalCache(&cache);
    defer if (prev_cache) |c| decision_cache.setGlobalCache(c) else decision_cache.clearGlobalCache();

    // A nonzero auth_version: these decisions are cached.
    const ro = testPrincipal("otto", &.{"ReadOnly"}, 7);
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g1")); // served from the cache
    try grant(&w.pol, "otto", "g1", WRITE);
    try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g2"));
    revoke(&w.pol, "otto", "g1", WRITE);
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(cache.getHits() > 0);
}

test "gps: an allow policy FOR WRITE scoped to g1 allows writes on g1 only, not database-wide" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ro = testPrincipal("otto", &.{"ReadOnly"}, 0);
    const actions = [_]policy_catalog.Action{.write};
    try w.cat.addPolicy(.{
        .name = "otto_writes_g1",
        .scope_graph = "g1",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "current_user() = 'otto'",
        .enabled = true,
    });
    try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g2"));
    try testing.expect(!gps.writePermitted(testing.allocator, &ro));
    // A `*` policy still covers every graph and the database.
    try w.cat.addPolicy(.{
        .name = "otto_writes_all",
        .scope_graph = "*",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "current_user() = 'otto'",
        .enabled = true,
    });
    try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g2"));
    try testing.expect(gps.writePermitted(testing.allocator, &ro));
}

test "gRPC: a FOR WRITE policy scoped to g1 does not let a readonly user write g2" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const actions = [_]policy_catalog.Action{.write};
    try w.cat.addPolicy(.{
        .name = "otto_writes_g1",
        .scope_graph = "g1",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "current_user() = 'otto'",
        .enabled = true,
    });
    const s1 = try w.session("otto", .ReadOnly, "g1");
    const s2 = try w.session("otto", .ReadOnly, "g2");
    try expectRuns(ga, s1, "CREATE (:P {v: 1})");
    try expectDenied(ga, s2, "CREATE (:P {v: 2})");
    try testing.expectEqual(@as(usize, 1), countIn("g1", "P"));
    try testing.expectEqual(@as(usize, 0), countIn("g2", "P"));
}

test "gps: a deny policy on g1 overrides a WRITE grant on g1, and leaves g2 alone" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ro = testPrincipal("otto", &.{"ReadOnly"}, 0);
    const rw = testPrincipal("rita", &.{"ReadWrite"}, 0);
    try grant(&w.pol, "otto", "g1", WRITE);
    try grant(&w.pol, "otto", "g2", WRITE);
    const actions = [_]policy_catalog.Action{.write};
    try w.cat.addPolicy(.{
        .name = "no_writes_g1",
        .scope_graph = "g1",
        .actions = &actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = true,
    });
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g2"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &rw, "g1"));
    try testing.expect(gps.writePermittedOn(testing.allocator, &rw, "g2"));
}

// ---------------------------------------------------------------------------
// SCHEMA
// ---------------------------------------------------------------------------

test "gps: GRANT SCHEMA ON GRAPH g1 gives schema on g1 at once, nowhere else; REVOKE takes it at once" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // readwrite holds no global Schema; it binds any graph in a single-tenant
    // deployment, which `maySchema` also needs.
    const rw = testPrincipal("rita", &.{"ReadWrite"}, 0);
    try testing.expect(!session_graph.maySchema(&rw, "g1"));
    try grant(&w.pol, "rita", "g1", SCHEMA);
    try testing.expect(session_graph.maySchema(&rw, "g1"));
    try testing.expect(!session_graph.maySchema(&rw, "g2"));
    // Index and constraint DDL bind every graph: a grant on one graph does
    // not give schema on the whole database (SONNY-3030).
    try testing.expect(!session_graph.maySchemaDatabase(&rw));
    revoke(&w.pol, "rita", "g1", SCHEMA);
    try testing.expect(!session_graph.maySchema(&rw, "g1"));
}

test "gRPC: GRANT SCHEMA ON GRAPH lets a readwrite user create that graph at once, and no other" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const st = graph_store.getGlobalStore(testing.allocator);
    const s = try w.session("rita", .ReadWrite, null);
    try expectDenied(ga, s, "CREATE GRAPH g_rita");
    try grant(&w.pol, "rita", "g_rita", SCHEMA);
    try expectRuns(ga, s, "CREATE GRAPH g_rita");
    try testing.expect(st.graphExists("g_rita"));
    try expectDenied(ga, s, "CREATE GRAPH g_other");
    try testing.expect(!st.graphExists("g_other"));
    revoke(&w.pol, "rita", "g_rita", SCHEMA);
    try expectDenied(ga, s, "DROP GRAPH g_rita");
    try testing.expect(st.graphExists("g_rita"));
}

// ---------------------------------------------------------------------------
// Global roles: unchanged (a guard, not a regression of the bug)
// ---------------------------------------------------------------------------

test "gps and gRPC: global-role users are unchanged" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const rw = testPrincipal("rita", &.{"ReadWrite"}, 0);
    const ro = testPrincipal("otto", &.{"ReadOnly"}, 0);
    const user = testPrincipal("uma", &.{"User"}, 0);
    const admin = testPrincipal("ada", &.{"Admin"}, 0);
    for ([_][]const u8{ "g1", "g2", graph_store.DEFAULT_GRAPH_NAME }) |g| {
        try testing.expect(gps.writePermittedOn(testing.allocator, &rw, g));
        try testing.expect(gps.writePermittedOn(testing.allocator, &admin, g));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, g));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &user, g));
        for ([_]*const principal_mod.Principal{ &rw, &ro, &user, &admin }) |p| {
            try testing.expect(gps.graphReadPermitted(testing.allocator, p, g));
        }
        try testing.expect(session_graph.maySchema(&admin, g));
        try testing.expect(!session_graph.maySchema(&rw, g));
    }
    try testing.expect(gps.writePermitted(testing.allocator, &rw));
    try testing.expect(gps.writePermitted(testing.allocator, &admin));
    try testing.expect(!gps.writePermitted(testing.allocator, &ro));
    try testing.expect(session_graph.maySchemaDatabase(&admin));

    const s_rw = try w.session("rita", .ReadWrite, null);
    try expectRuns(ga, s_rw, "CREATE (:R {v: 1})");
    try expectRuns(ga, s_rw, "USE GRAPH g1; CREATE (:R {v: 2})");
    try expectRuns(ga, s_rw, "USE GRAPH g2; CREATE (:R {v: 3})");
    const s_ro = try w.session("otto", .ReadOnly, null);
    try expectRuns(ga, s_ro, "MATCH (n:Seed) RETURN count(n) AS c");
    try expectDenied(ga, s_ro, "CREATE (:O {v: 1})");
    const s_admin = try w.session("ada", .Admin, null);
    try expectRuns(ga, s_admin, "USE GRAPH g2; CREATE (:A {v: 1})");
}

// ---------------------------------------------------------------------------
// Restart: grants survive it, scoped; REVOKE works after it
// ---------------------------------------------------------------------------

const HMAC_KEY = [_]u8{0x5a} ** 32;

/// The security state a server builds at startup from `agm`'s store
/// (`server_init.wireAuthDDLCallbacks` and `wireGpsPolicyHooks`): the live
/// grant table from the stored grants, and the policy catalog from the
/// stored policies, then the startup grant/policy step.
const Booted = struct {
    pol: mgs.GraphRBACPolicy,
    cat: PolicyCatalog,

    fn boot(self: *Booted, agm: *AuthGraphManager) !void {
        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        errdefer self.pol.deinit();
        const grants = try agm.listGraphGrants(testing.allocator);
        defer testing.allocator.free(grants);
        for (grants) |g| try self.pol.grantGraphPermission(g.user_id, g.getGraphName(), g.action);
        mgs.setGlobalPolicy(&self.pol);

        self.cat = PolicyCatalog.init(testing.allocator);
        errdefer self.cat.deinit();
        try policy_persistence.hydrateCatalog(testing.allocator, agm, &self.cat);
        _ = try grant_migration.retireMigratedGrantPolicies(testing.allocator, agm, &HMAC_KEY, &self.cat);
        policy_catalog.setGlobalCatalog(&self.cat);
    }

    fn shutdown(self: *Booted) void {
        policy_catalog.clearGlobalCatalog();
        mgs.setGlobalPolicy(null);
        self.cat.deinit();
        self.pol.deinit();
    }
};

/// GRANT as `server_init.grantApply` runs it: persist, then the live table.
fn grantPersisted(agm: *AuthGraphManager, uid: u64, graph: []const u8, action: u8) !void {
    try agm.grantUserGraphPermission(&HMAC_KEY, uid, graph, action);
    if (mgs.getGlobalPolicy()) |pol| try pol.grantGraphPermission(uid, graph, action);
}

/// REVOKE as `server_init.grantRevoke` runs it.
fn revokePersisted(agm: *AuthGraphManager, uid: u64, graph: []const u8, action: u8) !void {
    _ = try agm.revokeUserGraphPermission(&HMAC_KEY, uid, graph, action);
    if (mgs.getGlobalPolicy()) |pol| _ = pol.revokeGraphPermission(uid, graph, action);
}

test "restart: grants survive scoped to their graph, and REVOKE after the restart takes effect at once" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var agm = try AuthGraphManager.init(testing.allocator, &store);
    defer agm.deinit();
    AuthGraphManager.setGlobal(&agm);
    defer AuthGraphManager.setGlobal(null);
    const prev_grant_fn = geode.execution.graph_grant_check_fn;
    geode.execution.graph_grant_check_fn = &agmGrantCheck;
    defer geode.execution.graph_grant_check_fn = prev_grant_fn;
    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);

    const otto_id = try agm.createUser(&HMAC_KEY, "otto", "otto@example.com", "not_a_real_hash", false);
    const nora_id = try agm.createUser(&HMAC_KEY, "nora", "nora@example.com", "not_a_real_hash", false);
    const ro = testPrincipal("otto", &.{"ReadOnly"}, 0);
    const none = testPrincipal("nora", &[_][]const u8{@tagName(Role.None)}, 0);

    // First run: the grants, issued at runtime.
    {
        var b: Booted = undefined;
        try b.boot(&agm);
        defer b.shutdown();
        try grantPersisted(&agm, otto_id, "g1", READ);
        try grantPersisted(&agm, otto_id, "g1", WRITE);
        try grantPersisted(&agm, otto_id, "g2", READ);
        try grantPersisted(&agm, nora_id, "g1", READ);
        try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g1"));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g2"));
    }

    // Restart: the same grants, scoped as before.
    {
        var b: Booted = undefined;
        try b.boot(&agm);
        defer b.shutdown();
        try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g1"));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g2"));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, graph_store.DEFAULT_GRAPH_NAME));
        try testing.expect(!gps.writePermitted(testing.allocator, &ro));
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&ro, .bind_graph, .{ .graph = "g2" }));
        try testing.expect(gps.graphReadPermitted(testing.allocator, &none, "g1"));
        try testing.expect(!gps.graphReadPermitted(testing.allocator, &none, "g2"));
        try testing.expect(!gps.writePermittedOn(testing.allocator, &none, "g1"));

        // REVOKE after the restart: at once.
        try revokePersisted(&agm, otto_id, "g1", WRITE);
        try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g1"));
        try revokePersisted(&agm, nora_id, "g1", READ);
        try testing.expect(!gps.graphReadPermitted(testing.allocator, &none, "g1"));
        try testing.expect(try decideKind(&none, .bind_graph, .{ .graph = "g1" }) != .allow);
    }

    // And after another restart, the revokes hold and the rest survives.
    {
        var b: Booted = undefined;
        try b.boot(&agm);
        defer b.shutdown();
        try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g1"));
        try testing.expect(!gps.graphReadPermitted(testing.allocator, &none, "g1"));
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&ro, .bind_graph, .{ .graph = "g1" }));
    }
    try agm.verifyChain(&HMAC_KEY);
}

test "restart: a database an older version migrated grants into Policy rows loses the rows, keeps the grants" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var agm = try AuthGraphManager.init(testing.allocator, &store);
    defer agm.deinit();
    AuthGraphManager.setGlobal(&agm);
    defer AuthGraphManager.setGlobal(null);
    const prev_grant_fn = geode.execution.graph_grant_check_fn;
    geode.execution.graph_grant_check_fn = &agmGrantCheck;
    defer geode.execution.graph_grant_check_fn = prev_grant_fn;

    const otto_id = try agm.createUser(&HMAC_KEY, "otto", "otto@example.com", "not_a_real_hash", false);
    try agm.grantUserGraphPermission(&HMAC_KEY, otto_id, "g1", WRITE);
    // The row an older version's startup migrated that grant into, plus one
    // for a grant since revoked (its (:GraphGrant) is gone).
    const write = [_]policy_catalog.Action{.write};
    for ([_][]const u8{ "g1", "g9" }) |g| {
        const name = try std.fmt.allocPrint(testing.allocator, "auto_migrated_grant_otto_{s}_write", .{g});
        defer testing.allocator.free(name);
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, .{
            .name = name,
            .scope_graph = g,
            .actions = &write,
            .effect = .allow,
            .expression_source = "current_user() = 'otto'",
            .enabled = true,
        });
    }

    const ro = testPrincipal("otto", &.{"ReadOnly"}, 0);
    var b: Booted = undefined;
    try b.boot(&agm);
    defer b.shutdown();
    for (b.cat.listPolicies()) |p| {
        try testing.expect(!std.mem.startsWith(u8, p.name, grant_migration.migrated_policy_prefix));
    }
    // The grant: on g1 only. The revoked grant's row no longer allows g9.
    try testing.expect(gps.writePermittedOn(testing.allocator, &ro, "g1"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g9"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g2"));
    try agm.verifyChain(&HMAC_KEY);
}
